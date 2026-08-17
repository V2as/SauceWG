#!/usr/bin/env bash
# Multiple exit-node uplinks with health-based failover and live reconfiguration.
#
# Every configured exit node gets its own AmneziaWG interface, its own persistent
# private key and its own obfuscation profile. All of them stay up and keep
# handshaking, so a failover is a single route swap rather than a tunnel rebuild.
#
# Only the interface named in the client policy-routing table carries traffic:
#
#     ip rule from <client subnet> lookup 451
#     ip route default dev <active uplink> table 451
#
# The monitor loop re-evaluates health every CASCADE_PROBE_INTERVAL seconds and
# rewrites that one route when a better uplink is available. It also watches the
# exit node list and applies additions and removals in place — only the interfaces
# that actually changed are rebuilt, so adding an exit node never disturbs the one
# currently carrying client traffic.

UPLINK_STATE_FILE=${UPLINK_STATE_FILE:-/var/run/amneziawg/uplinks.json}
UPLINK_CONTROL_FILE=${UPLINK_CONTROL_FILE:-/var/run/amneziawg/uplink-control.json}
UPLINK_RELOAD_FILE=${UPLINK_RELOAD_FILE:-/var/run/amneziawg/reload.request}

CASCADE_IFACE_PREFIX=${CASCADE_IFACE_PREFIX:-awg}
CASCADE_IFACE_OFFSET=${CASCADE_IFACE_OFFSET:-1}
CASCADE_NODES_FILE=${CASCADE_NODES_FILE:-/etc/amnezia/exit-nodes.json}
CASCADE_UPLINK_SUBNET=${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}
# The entrypoint sets these too; defaulting them here as well keeps this file
# sourceable on its own, which is what the reload tests do.
CASCADE_TABLE=${CASCADE_TABLE:-451}
CASCADE_RULE_PRIORITY=${CASCADE_RULE_PRIORITY:-451}

CASCADE_PROBE_ENABLED=${CASCADE_PROBE_ENABLED:-true}
CASCADE_PROBE_TARGET=${CASCADE_PROBE_TARGET:-1.1.1.1}
CASCADE_PROBE_INTERVAL=${CASCADE_PROBE_INTERVAL:-10}
CASCADE_PROBE_TIMEOUT=${CASCADE_PROBE_TIMEOUT:-3}
CASCADE_FAIL_THRESHOLD=${CASCADE_FAIL_THRESHOLD:-3}
CASCADE_RECOVER_THRESHOLD=${CASCADE_RECOVER_THRESHOLD:-2}
CASCADE_HANDSHAKE_TIMEOUT=${CASCADE_HANDSHAKE_TIMEOUT:-180}

# Interface numbers are handed out per node name and persisted here, so removing a
# node in the middle of the list does not renumber — and silently reconfigure — the
# ones that survive it.
UPLINK_SLOTS_FILE=${UPLINK_SLOTS_FILE:-${AWG_CONFIG_DIR:-/etc/amnezia/amneziawg}/uplink-slots.json}

# Parallel arrays, one slot per configured exit node.
UP_NAME=(); UP_IFACE=(); UP_ENDPOINT=(); UP_PEERKEY=(); UP_PSK=(); UP_ADDR=()
UP_PRIO=(); UP_MTU=(); UP_KEEPALIVE=(); UP_PROTOCOL=()
UP_PUBKEY=(); UP_HEALTHY=(); UP_FAILS=(); UP_OKS=(); UP_LATENCY=(); UP_HS=(); UP_RX=(); UP_TX=()
UP_PID=()

# Obfuscation is keyed "<slot>,<suffix>" rather than kept in an array per
# parameter: an uplink carries up to sixteen of them, and which ones depend on the
# protocol generation, so one map keeps the reload bookkeeping from having to
# grow a branch for every new parameter Amnezia adds.
declare -A UP_OBF=()

declare -A UPLINK_SLOT_OF=()

ACTIVE_INDEX=-1
UPLINK_MODE=auto
UPLINK_PIN=""
NO_HEALTHY_LOGGED=false
# The id of the last reload request the monitor finished applying. Whoever wrote
# the request polls for it in uplinks.json to know the change went live.
RELOAD_ID=0
CONFIG_ERROR=""
# Where the exit node list was read from on the last parse: file, env, legacy-env or
# none. Published so the panel can warn when its writes are being overridden.
CONFIG_SOURCE="file"

uplink_slug() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

uplink_count() {
    printf '%s' "${#UP_NAME[@]}"
}

uplink_index_of() {
    local name=$1 i
    for i in "${!UP_NAME[@]}"; do
        if [ "${UP_NAME[$i]}" = "$name" ]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Which of the ways of supplying the exit node list is in effect. The panel edits the
# file, so it has to be able to tell when something else is taking precedence.
uplinks_config_source() {
    if [ -n "${CASCADE_NODES_JSON:-}" ]; then
        printf 'env'
    elif [ -f "$CASCADE_NODES_FILE" ]; then
        printf 'file'
    elif [ -n "${CASCADE_ENDPOINT:-}" ] || [ -n "${CASCADE_PEER_PUBLIC_KEY:-}" ]; then
        printf 'legacy-env'
    else
        printf 'none'
    fi
}

# Emits the exit-node list as a JSON array, whichever way the operator supplied it.
uplinks_source_json() {
    case "$(uplinks_config_source)" in
        env)  printf '%s' "$CASCADE_NODES_JSON" ;;
        file) cat "$CASCADE_NODES_FILE" ;;
        # The single-uplink variables, so an existing .env keeps working.
        legacy-env)
            local args=() suffix name
            for suffix in $AWG_OBF_SUFFIXES; do
                name="CASCADE_${suffix}"
                args+=(--arg "$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')" "${!name:-}")
            done
            jq -n \
                --arg name "${CASCADE_NAME:-exit-1}" \
                --arg endpoint "${CASCADE_ENDPOINT:-}" \
                --arg key "${CASCADE_PEER_PUBLIC_KEY:-}" \
                --arg psk "${CASCADE_PEER_PSK:-}" \
                --arg address "${CASCADE_ADDRESS:-}" \
                --arg protocol "${CASCADE_PROTOCOL:-}" \
                "${args[@]}" \
                '[{name: $name, endpoint: $endpoint, public_key: $key, preshared_key: $psk,
                   address: $address, priority: 10, protocol: $protocol,
                   jc: $jc, jmin: $jmin, jmax: $jmax,
                   s1: $s1, s2: $s2, s3: $s3, s4: $s4,
                   h1: $h1, h2: $h2, h3: $h3, h4: $h4,
                   i1: $i1, i2: $i2, i3: $i3, i4: $i4, i5: $i5}]'
            ;;
        *) printf '[]' ;;
    esac
}

# One value out of an uplink's persisted parameters, without sourcing the file into
# the caller's scope. params_store single-quotes anything that needs it.
uplink_saved_param() {
    local slug=$1 key=$2 file value
    file="${AWG_CONFIG_DIR}/uplink-${slug}.params"
    [ -f "$file" ] || return 0
    value=$(sed -n "s/^${key}=//p" "$file" | tail -n1)
    case $value in
        "'"*"'") value=${value#\'}; value=${value%\'}; value=${value//\'\\\'\'/\'} ;;
    esac
    printf '%s' "$value"
}

# Which AmneziaWG generation one uplink speaks. The exit node's own list entry
# decides, since it is the end that has to answer the handshake; an uplink that
# has been running since before protocol selection existed keeps speaking 1.0.
#
# Resolved here rather than at setup time so that uplink_signature compares a
# canonical value on both sides of a reload and does not rebuild a healthy tunnel
# just because the list spells the generation differently.
uplink_resolve_protocol() {
    local name=$1 requested=$2 slug resolved
    slug=$(uplink_slug "$name")

    if [ -z "$requested" ]; then
        requested=$(uplink_saved_param "$slug" UPLINK_PROTOCOL)
    fi
    if [ -z "$requested" ]; then
        if [ -n "$(uplink_saved_param "$slug" UPLINK_S1)" ]; then
            requested=1.0
        else
            requested=${CASCADE_PROTOCOL_DEFAULT:-1.0}
        fi
    fi
    if ! resolved=$(awg_protocol "$requested"); then
        log "uplink ${name}: ${requested} is not an AmneziaWG generation; using 1.0"
        resolved=1.0
    fi
    printf '%s' "$resolved"
}

uplinks_load_slots() {
    UPLINK_SLOT_OF=()
    [ -f "$UPLINK_SLOTS_FILE" ] || return 0
    local name slot
    while IFS=$'\x1f' read -r name slot; do
        [ -n "$name" ] || continue
        UPLINK_SLOT_OF[$name]=$slot
    done < <(jq -r 'to_entries[] | "\(.key)\u001f\(.value)"' "$UPLINK_SLOTS_FILE" 2>/dev/null)
}

uplinks_save_slots() {
    local name tmp="${UPLINK_SLOTS_FILE}.tmp"
    if [ "${#UPLINK_SLOT_OF[@]}" -eq 0 ]; then
        printf '{}\n' > "$tmp"
    else
        for name in "${!UPLINK_SLOT_OF[@]}"; do
            printf '%s\x1f%s\n' "$name" "${UPLINK_SLOT_OF[$name]}"
        done | jq -R -s '
            split("\n") | map(select(length > 0) | split("\u001f")
            | {key: .[0], value: (.[1] | tonumber)}) | from_entries' > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 0; }
    fi
    mv "$tmp" "$UPLINK_SLOTS_FILE"
}

# Gives every configured node an interface, reusing the number it had last time.
uplinks_allocate_ifaces() {
    local i name slot taken=" "
    local -A chosen=()

    uplinks_load_slots
    for i in "${!UP_NAME[@]}"; do
        name=${UP_NAME[$i]}
        slot=${UPLINK_SLOT_OF[$name]:-}
        [ -n "$slot" ] || continue
        case "$taken" in *" $slot "*) continue ;; esac
        chosen[$i]=$slot
        taken="${taken}${slot} "
    done
    for i in "${!UP_NAME[@]}"; do
        [ -z "${chosen[$i]:-}" ] || continue
        slot=$CASCADE_IFACE_OFFSET
        while :; do
            case "$taken" in *" $slot "*) slot=$((slot + 1)) ;; *) break ;; esac
        done
        chosen[$i]=$slot
        taken="${taken}${slot} "
    done

    UPLINK_SLOT_OF=()
    for i in "${!UP_NAME[@]}"; do
        UP_IFACE[i]="${CASCADE_IFACE_PREFIX}${chosen[$i]}"
        UPLINK_SLOT_OF[${UP_NAME[$i]}]=${chosen[$i]}
    done
    uplinks_save_slots
}

# Fills the UP_* arrays. Returns non-zero — without touching the arrays — when the
# list is not valid JSON, so a bad edit during a reload cannot take the node down.
uplinks_parse() {
    local json idx=0 base

    CONFIG_SOURCE=$(uplinks_config_source)
    json=$(uplinks_source_json)
    if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        CONFIG_ERROR="the exit node list is not a JSON array"
        return 1
    fi
    CONFIG_ERROR=""

    UP_NAME=(); UP_IFACE=(); UP_ENDPOINT=(); UP_PEERKEY=(); UP_PSK=(); UP_ADDR=()
    UP_PRIO=(); UP_MTU=(); UP_KEEPALIVE=(); UP_PROTOCOL=()
    UP_PUBKEY=(); UP_HEALTHY=(); UP_FAILS=(); UP_OKS=(); UP_LATENCY=(); UP_HS=()
    UP_RX=(); UP_TX=(); UP_PID=()
    UP_OBF=()

    base=${CASCADE_UPLINK_SUBNET%%/*}
    base=${base%.*}

    # Fields are joined with US (0x1f) rather than tabs: `read` treats tab as IFS
    # whitespace and would collapse the runs of empty optional fields, shifting
    # every later column.
    local name endpoint peerkey psk addr prio mtu keepalive protocol suffix
    while IFS=$'\x1f' read -r name endpoint peerkey psk addr prio mtu keepalive protocol; do
        [ -n "$name" ] || name="exit-$((idx + 1))"

        UP_NAME[idx]=$name
        UP_ENDPOINT[idx]=$endpoint
        UP_PEERKEY[idx]=$peerkey
        UP_PSK[idx]=$psk
        # Each uplink terminates on its own address inside the shared uplink subnet.
        UP_ADDR[idx]=${addr:-${base}.$((idx + 2))/32}
        UP_PRIO[idx]=${prio:-$((idx + 1))}
        UP_MTU[idx]=${mtu:-${CASCADE_MTU:-1380}}
        UP_KEEPALIVE[idx]=${keepalive:-${CASCADE_KEEPALIVE:-25}}
        UP_PROTOCOL[idx]=$(uplink_resolve_protocol "$name" "$protocol")
        for suffix in $AWG_OBF_SUFFIXES; do
            UP_OBF[$idx,$suffix]=""
        done

        UP_IFACE[idx]=""
        UP_PUBKEY[idx]=""
        UP_HEALTHY[idx]=true
        UP_FAILS[idx]=0
        UP_OKS[idx]=0
        UP_LATENCY[idx]=""
        UP_HS[idx]=0
        UP_RX[idx]=0
        UP_TX[idx]=0
        UP_PID[idx]=0

        idx=$((idx + 1))
    done < <(printf '%s' "$json" | jq -r '
        def s: if . == null then "" else tostring end;
        map(with_entries(.key |= ascii_downcase))[] | [
            (.name | s),
            (.endpoint | s),
            ((.public_key // .peer_public_key) | s),
            ((.preshared_key // .psk) | s),
            (.address | s),
            (.priority | s),
            (.mtu | s),
            (.keepalive | s),
            ((.protocol // .version) | s)
        ] | join("\u001f")')

    # Obfuscation arrives as its own stream of (slot, parameter, value) triples so
    # that adding a parameter to AWG_OBF_SUFFIXES needs no new column here.
    local slot value
    while IFS=$'\x1f' read -r slot suffix value; do
        [ -n "$slot" ] || continue
        UP_OBF[$slot,$suffix]=$value
    done < <(printf '%s' "$json" | jq -r --arg suffixes "$AWG_OBF_SUFFIXES" '
        def s: if . == null then "" else tostring end;
        ($suffixes | split(" ")) as $obf
        | to_entries[]
        | .key as $slot
        | (.value | with_entries(.key |= ascii_downcase)) as $node
        | $obf[] as $suffix
        | [($slot | tostring), $suffix, ($node[$suffix | ascii_downcase] | s)]
        | join("\u001f")')

    # Nothing configured yet: bring up one unpaired uplink anyway so the entry node
    # publishes a public key to pair the first exit node with, and so the kill
    # switch is already in force.
    if [ "$idx" -eq 0 ]; then
        log "no exit node is configured; starting a single unpaired uplink"
        UP_NAME[0]="exit-1"
        UP_ENDPOINT[0]=""
        UP_PEERKEY[0]=""
        UP_PSK[0]=""
        UP_ADDR[0]="${base}.2/32"
        UP_PRIO[0]=1
        UP_MTU[0]=${CASCADE_MTU:-1380}
        UP_KEEPALIVE[0]=${CASCADE_KEEPALIVE:-25}
        UP_PROTOCOL[0]=$(uplink_resolve_protocol "exit-1" "")
        for suffix in $AWG_OBF_SUFFIXES; do
            UP_OBF[0,$suffix]=""
        done
        UP_IFACE[0]=""
        UP_PUBKEY[0]=""
        UP_HEALTHY[0]=false
        UP_FAILS[0]=0
        UP_OKS[0]=0
        UP_LATENCY[0]=""
        UP_HS[0]=0
        UP_RX[0]=0
        UP_TX[0]=0
        UP_PID[0]=0
    fi

    uplinks_allocate_ifaces
    return 0
}

# Everything that, when it changes, means the interface has to be rebuilt. Priority
# is deliberately absent: reordering the cascade is a routing decision, not a
# reason to drop a working tunnel.
uplink_signature() {
    local i=$1 suffix
    printf '%s|%s|%s|%s|%s|%s|%s|%s' \
        "${UP_IFACE[$i]}" "${UP_ENDPOINT[$i]}" "${UP_PEERKEY[$i]}" "${UP_PSK[$i]}" \
        "${UP_ADDR[$i]}" "${UP_MTU[$i]}" "${UP_KEEPALIVE[$i]}" "${UP_PROTOCOL[$i]}"
    for suffix in $AWG_OBF_SUFFIXES; do
        printf '|%s' "${UP_OBF[$i,$suffix]:-}"
    done
}

# ---------------------------------------------------------------------------
# Interfaces
# ---------------------------------------------------------------------------

uplink_setup() {
    local i=$1
    local name=${UP_NAME[$i]} iface=${UP_IFACE[$i]}
    local slug keyfile parfile priv conf suffix supplied saved protocol

    slug=$(uplink_slug "$name")
    keyfile="${AWG_CONFIG_DIR}/uplink-${slug}.key"
    parfile="${AWG_CONFIG_DIR}/uplink-${slug}.params"

    unset UPLINK_PROTOCOL
    for suffix in $AWG_OBF_SUFFIXES; do
        unset "UPLINK_${suffix}"
    done
    params_load "$parfile"

    if [ -f "$keyfile" ]; then
        priv=$(cat "$keyfile")
    else
        priv=$(awg_genkey)
        log "generated a private key for uplink ${name}"
    fi
    store_secret "$keyfile" "$priv"

    protocol=${UP_PROTOCOL[$i]}

    # An explicit value in the node list wins, then whatever was persisted on an
    # earlier start, and only then a freshly generated profile.
    for suffix in $AWG_OBF_SUFFIXES; do
        supplied=${UP_OBF[$i,$suffix]:-}
        saved="UPLINK_${suffix}"
        if [ -n "$supplied" ]; then
            printf -v "NODE_${suffix}" '%s' "$supplied"
        else
            printf -v "NODE_${suffix}" '%s' "${!saved:-}"
        fi
    done
    generate_obfuscation "NODE_" "$protocol" nodes

    UP_PUBKEY[i]=$(awg_pubkey "$priv")

    conf="${AWG_CONFIG_DIR}/${iface}.conf"
    {
        echo "[Interface]"
        echo "PrivateKey = ${priv}"
        emit_obfuscation "NODE_" "$protocol"
        if [ -n "${UP_PEERKEY[$i]}" ] && [ -n "${UP_ENDPOINT[$i]}" ]; then
            echo
            echo "[Peer]"
            echo "PublicKey = ${UP_PEERKEY[$i]}"
            [ -n "${UP_PSK[$i]}" ] && echo "PresharedKey = ${UP_PSK[$i]}"
            echo "AllowedIPs = 0.0.0.0/0"
            echo "Endpoint = ${UP_ENDPOINT[$i]}"
            echo "PersistentKeepalive = ${UP_KEEPALIVE[$i]}"
        else
            log "uplink ${name} has no peer yet; ${iface} starts unpaired"
        fi
    } > "$conf"
    chmod 0600 "$conf"

    ip link del "$iface" 2>/dev/null || true
    amneziawg-go -f "$iface" &
    UP_PID[i]=$!

    if ! wait_for_socket "$iface"; then
        log "uplink ${name}: ${iface} never opened its UAPI socket"
        uplink_stop "$i"
        return 1
    fi
    if ! awg setconf "$iface" "$conf"; then
        log "uplink ${name}: could not apply ${conf}"
        uplink_stop "$i"
        return 1
    fi
    if ! iface_up "$iface" "${UP_ADDR[$i]}" "${UP_MTU[$i]}"; then
        log "uplink ${name}: could not bring ${iface} up on ${UP_ADDR[$i]}"
        uplink_stop "$i"
        return 1
    fi

    # shellcheck disable=SC2034  # params_store reads these by name
    {
        UPLINK_NAME=$name
        UPLINK_IFACE=$iface
        UPLINK_PUBLIC_KEY=${UP_PUBKEY[$i]}
        UPLINK_PEER_PUBLIC_KEY=${UP_PEERKEY[$i]}
        UPLINK_ENDPOINT=${UP_ENDPOINT[$i]}
        UPLINK_ADDRESS=${UP_ADDR[$i]}
        UPLINK_PROTOCOL=$protocol
    }
    local stored=(UPLINK_NAME UPLINK_IFACE UPLINK_PUBLIC_KEY UPLINK_PEER_PUBLIC_KEY
                  UPLINK_ENDPOINT UPLINK_ADDRESS UPLINK_PROTOCOL)
    local source_name
    for suffix in $AWG_OBF_SUFFIXES; do
        source_name="NODE_${suffix}"
        printf -v "UPLINK_${suffix}" '%s' "${!source_name:-}"
        stored+=("UPLINK_${suffix}")
    done
    params_store "$parfile" "${stored[@]}"

    log "uplink ${name} up on ${iface} (${UP_ADDR[$i]}) speaking AmneziaWG ${protocol} towards ${UP_ENDPOINT[$i]:-<unpaired>} (pub ${UP_PUBKEY[$i]})"
    return 0
}

# Stops the process and drops the interface behind one slot of the current list.
uplink_stop() {
    local i=$1
    uplink_stop_raw "${UP_IFACE[$i]}" "${UP_PID[$i]:-0}"
    UP_PID[i]=0
}

uplink_stop_raw() {
    local iface=$1 pid=${2:-0}
    if [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        # The monitor owns these processes, so reap them instead of leaving zombies.
        wait "$pid" 2>/dev/null || true
    fi
    [ -n "$iface" ] && ip link del "$iface" 2>/dev/null
    return 0
}

uplinks_setup_all() {
    local i
    for i in "${!UP_NAME[@]}"; do
        uplink_setup "$i" || true
    done
}

uplinks_teardown() {
    local i
    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_TABLE" 2>/dev/null || true
    ip route flush table "$CASCADE_TABLE" 2>/dev/null || true
    for i in "${!UP_NAME[@]}"; do
        ip link del "${UP_IFACE[$i]}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

uplink_rules_add() {
    local iface=$1
    iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE
    # Inserted at the top so the kill switch's REJECT rule stays last in the chain.
    iptables -C FORWARD -i "$AWG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$AWG_IFACE" -o "$iface" -j ACCEPT
    iptables -C FORWARD -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

uplink_rules_del() {
    local iface=$1
    iptables -t nat -D POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$AWG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

# Rules that apply to every uplink. Only the default route inside CASCADE_TABLE
# decides which one actually carries client traffic.
uplinks_routing_base() {
    local i

    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_TABLE" 2>/dev/null || true
    ip rule add from "$AWG_SUBNET" lookup "$CASCADE_TABLE" priority "$CASCADE_RULE_PRIORITY"

    for i in "${!UP_NAME[@]}"; do
        uplink_rules_add "${UP_IFACE[$i]}"
    done

    if [ "${CASCADE_KILLSWITCH:-true}" = "true" ]; then
        # Nothing else may forward client traffic, so a dead uplink cannot leak
        # through the entry node's own address.
        iptables -C FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null \
            || iptables -A FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable
    fi

    iptables -t mangle -C FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

# Points the client policy-routing table at one uplink. Pass "force" after a
# rebuild, when the route has to be rewritten even though the choice is unchanged.
uplink_activate() {
    local i=$1 force=${2:-}
    local previous=$ACTIVE_INDEX

    [ "$i" -ne "$previous" ] || [ "$force" = "force" ] || return 0

    ip route replace default dev "${UP_IFACE[$i]}" table "$CASCADE_TABLE"
    ACTIVE_INDEX=$i

    if [ "$previous" -ge 0 ] && [ "$previous" -ne "$i" ]; then
        # Established flows are NATed to the old exit address and would otherwise
        # black-hole until their conntrack entries expire.
        conntrack -D -s "$AWG_SUBNET" >/dev/null 2>&1 || true
        log "failover: ${UP_NAME[$previous]} -> ${UP_NAME[$i]} (${UP_IFACE[$i]} -> ${UP_ENDPOINT[$i]:-<unpaired>})"
    else
        log "active uplink: ${UP_NAME[$i]} (${UP_IFACE[$i]} -> ${UP_ENDPOINT[$i]:-<unpaired>})"
    fi
}

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

# Succeeds when the uplink looks usable right now.
uplink_probe() {
    local i=$1
    local iface=${UP_IFACE[$i]}
    local hs="" now age rx="" tx="" out rtt

    # `awg show` fails while an interface is being rebuilt; that is a probe failure,
    # never a reason to take the monitor down.
    read -r _ hs < <(awg show "$iface" latest-handshakes 2>/dev/null | head -n1) || true
    [ -n "$hs" ] || hs=0
    UP_HS[i]=$hs

    read -r _ rx tx < <(awg show "$iface" transfer 2>/dev/null | head -n1) || true
    UP_RX[i]=${rx:-0}
    UP_TX[i]=${tx:-0}

    # An unpaired uplink can never carry traffic.
    if [ -z "${UP_PEERKEY[$i]}" ] || [ -z "${UP_ENDPOINT[$i]}" ]; then
        UP_LATENCY[i]=""
        return 1
    fi

    # No handshake at all, or one too old to still be live.
    if [ "$hs" -eq 0 ]; then
        UP_LATENCY[i]=""
        return 1
    fi
    now=$(date +%s)
    age=$((now - hs))
    if [ "$age" -gt "$CASCADE_HANDSHAKE_TIMEOUT" ]; then
        UP_LATENCY[i]=""
        return 1
    fi

    # The tunnel is alive; check that the far side still reaches the internet.
    if [ "$CASCADE_PROBE_ENABLED" = "true" ]; then
        if out=$(ping -I "$iface" -c 1 -W "$CASCADE_PROBE_TIMEOUT" -q "$CASCADE_PROBE_TARGET" 2>/dev/null); then
            rtt=$(printf '%s' "$out" | awk -F'/' '/min\/avg/ {print $5; exit}' 2>/dev/null) || rtt=""
            UP_LATENCY[i]=$rtt
        else
            UP_LATENCY[i]=""
            return 1
        fi
    fi
    return 0
}

# Consecutive-sample hysteresis keeps a flapping link from flapping the route.
uplinks_refresh_health() {
    local i pid
    for i in "${!UP_NAME[@]}"; do
        # A userspace tunnel that died takes its interface with it, so rebuild it
        # rather than reporting a permanently unhealthy node.
        pid=${UP_PID[$i]:-0}
        if [ "$pid" -le 0 ] 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; then
            log "uplink ${UP_NAME[$i]} is not running; restarting ${UP_IFACE[$i]}"
            if uplink_setup "$i"; then
                uplink_rules_add "${UP_IFACE[$i]}"
                [ "$i" -ne "$ACTIVE_INDEX" ] || uplink_activate "$i" force
            fi
        fi

        if uplink_probe "$i"; then
            UP_OKS[i]=$((UP_OKS[i] + 1))
            UP_FAILS[i]=0
            if [ "${UP_HEALTHY[$i]}" != "true" ] && [ "${UP_OKS[$i]}" -ge "$CASCADE_RECOVER_THRESHOLD" ]; then
                UP_HEALTHY[i]=true
                log "uplink ${UP_NAME[$i]} recovered"
            fi
        else
            UP_FAILS[i]=$((UP_FAILS[i] + 1))
            UP_OKS[i]=0
            if [ "${UP_HEALTHY[$i]}" != "false" ] && [ "${UP_FAILS[$i]}" -ge "$CASCADE_FAIL_THRESHOLD" ]; then
                UP_HEALTHY[i]=false
                log "uplink ${UP_NAME[$i]} failed ${UP_FAILS[$i]} checks in a row"
            fi
        fi
    done
}

uplinks_read_control() {
    local mode node
    UPLINK_MODE=auto
    UPLINK_PIN=""
    [ -f "$UPLINK_CONTROL_FILE" ] || return 0
    mode=$(jq -r '.mode // "auto"' "$UPLINK_CONTROL_FILE" 2>/dev/null) || return 0
    node=$(jq -r '.node // ""' "$UPLINK_CONTROL_FILE" 2>/dev/null) || return 0
    if [ "$mode" = "manual" ] && [ -n "$node" ] && [ "$node" != "null" ]; then
        UPLINK_MODE=manual
        UPLINK_PIN=$node
    fi
}

# Prints the index of the uplink that should carry traffic, or -1 when none is up.
# A pinned node is a preference, not a lock: if it is down the next healthy node
# still takes over, and the pin is honoured again once it recovers.
uplinks_select() {
    local i best=-1 bestprio=0
    if [ -n "$UPLINK_PIN" ]; then
        for i in "${!UP_NAME[@]}"; do
            if [ "${UP_NAME[$i]}" = "$UPLINK_PIN" ] && [ "${UP_HEALTHY[$i]}" = "true" ]; then
                printf '%s' "$i"
                return
            fi
        done
    fi
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_HEALTHY[$i]}" = "true" ] || continue
        if [ "$best" -lt 0 ] || [ "${UP_PRIO[$i]}" -lt "$bestprio" ]; then
            best=$i
            bestprio=${UP_PRIO[$i]}
        fi
    done
    printf '%s' "$best"
}

uplinks_write_state() {
    local i tmp="${UPLINK_STATE_FILE}.tmp" active_name="" is_active
    if [ "$ACTIVE_INDEX" -ge 0 ]; then
        active_name=${UP_NAME[$ACTIVE_INDEX]}
    fi

    if for i in "${!UP_NAME[@]}"; do
        if [ "$i" -eq "$ACTIVE_INDEX" ]; then is_active=true; else is_active=false; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${UP_NAME[$i]}" "${UP_IFACE[$i]}" "${UP_ENDPOINT[$i]}" "${UP_ADDR[$i]}" \
            "${UP_PRIO[$i]}" "${UP_PUBKEY[$i]}" "${UP_PEERKEY[$i]}" \
            "${UP_HEALTHY[$i]}" "$is_active" \
            "${UP_HS[$i]}" "${UP_LATENCY[$i]}" "${UP_RX[$i]}" "${UP_TX[$i]}" \
            "${UP_PROTOCOL[$i]}"
    done | jq -R -s \
        --arg mode "$UPLINK_MODE" \
        --arg pin "$UPLINK_PIN" \
        --arg active "$active_name" \
        --arg error "$CONFIG_ERROR" \
        --arg reload "$RELOAD_ID" \
        --arg source "${CONFIG_SOURCE:-file}" \
        --argjson now "$(date -u +%s)" \
        --argjson killswitch "$([ "${CASCADE_KILLSWITCH:-true}" = "true" ] && echo true || echo false)" '
        {
            updated_at: $now,
            reload_id: $reload,
            source: $source,
            config_error: (if $error == "" then null else $error end),
            mode: $mode,
            pinned: (if $pin == "" then null else $pin end),
            active: (if $active == "" then null else $active end),
            killswitch: $killswitch,
            nodes: (
                split("\n") | map(select(length > 0)) | map(split("\t")) | map({
                    name: .[0],
                    iface: .[1],
                    endpoint: (if .[2] == "" then null else .[2] end),
                    address: .[3],
                    priority: (.[4] | tonumber),
                    public_key: .[5],
                    peer_public_key: (if .[6] == "" then null else .[6] end),
                    healthy: (.[7] == "true"),
                    active: (.[8] == "true"),
                    last_handshake: (.[9] | tonumber),
                    latency_ms: (if .[10] == "" then null else (.[10] | tonumber) end),
                    rx_bytes: (.[11] | tonumber),
                    tx_bytes: (.[12] | tonumber),
                    protocol: (if .[13] == "" then null else .[13] end)
                })
            )
        }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$UPLINK_STATE_FILE"
        chmod 0644 "$UPLINK_STATE_FILE"
    else
        rm -f "$tmp"
        log "could not write ${UPLINK_STATE_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Live reconfiguration
# ---------------------------------------------------------------------------

uplinks_reload_request_id() {
    local id
    [ -f "$UPLINK_RELOAD_FILE" ] || { printf '0'; return; }
    id=$(jq -r '.id // 0' "$UPLINK_RELOAD_FILE" 2>/dev/null) || id=0
    printf '%s' "${id:-0}"
}

uplinks_config_mtime() {
    [ -f "$CASCADE_NODES_FILE" ] || { printf '0'; return; }
    stat -c %Y "$CASCADE_NODES_FILE" 2>/dev/null || printf '0'
}

# Applies the current exit node list to the running node. Interfaces whose
# configuration did not change keep running untouched, so adding or removing an
# exit node does not interrupt the one carrying client traffic.
uplinks_reload() {
    local i name previous_active="" rebuilt=0 removed=0 added=0
    local -A old_iface=() old_pid=() old_sig=() old_pub=() old_protocol=()
    local -A old_healthy=() old_fails=() old_oks=() old_hs=() old_rx=() old_tx=() old_lat=()

    [ "$ACTIVE_INDEX" -lt 0 ] || previous_active=${UP_NAME[$ACTIVE_INDEX]}

    for i in "${!UP_NAME[@]}"; do
        name=${UP_NAME[$i]}
        old_iface[$name]=${UP_IFACE[$i]}
        old_pid[$name]=${UP_PID[$i]:-0}
        old_sig[$name]=$(uplink_signature "$i")
        old_pub[$name]=${UP_PUBKEY[$i]}
        old_protocol[$name]=${UP_PROTOCOL[$i]}
        old_healthy[$name]=${UP_HEALTHY[$i]}
        old_fails[$name]=${UP_FAILS[$i]}
        old_oks[$name]=${UP_OKS[$i]}
        old_hs[$name]=${UP_HS[$i]}
        old_rx[$name]=${UP_RX[$i]}
        old_tx[$name]=${UP_TX[$i]}
        old_lat[$name]=${UP_LATENCY[$i]}
    done

    if ! uplinks_parse; then
        log "the exit node list is unusable (${CONFIG_ERROR}); keeping the running cascade"
        return 1
    fi

    # Interface numbers are recycled, so departed nodes must release theirs before
    # a new node can claim the same one.
    for name in "${!old_iface[@]}"; do
        uplink_index_of "$name" >/dev/null && continue
        log "removing uplink ${name} (${old_iface[$name]})"
        uplink_rules_del "${old_iface[$name]}"
        uplink_stop_raw "${old_iface[$name]}" "${old_pid[$name]}"
        removed=$((removed + 1))
    done

    ACTIVE_INDEX=-1
    for i in "${!UP_NAME[@]}"; do
        name=${UP_NAME[$i]}
        if [ -n "${old_iface[$name]:-}" ] \
            && [ "${old_sig[$name]}" = "$(uplink_signature "$i")" ] \
            && [ "${old_pid[$name]}" -gt 0 ] 2>/dev/null \
            && kill -0 "${old_pid[$name]}" 2>/dev/null; then
            UP_PID[i]=${old_pid[$name]}
            UP_PUBKEY[i]=${old_pub[$name]}
            # The generation is only resolved in uplink_setup, which a kept uplink
            # never reaches; without this the published state would forget it.
            UP_PROTOCOL[i]=${old_protocol[$name]}
            UP_HEALTHY[i]=${old_healthy[$name]}
            UP_FAILS[i]=${old_fails[$name]}
            UP_OKS[i]=${old_oks[$name]}
            UP_HS[i]=${old_hs[$name]}
            UP_RX[i]=${old_rx[$name]}
            UP_TX[i]=${old_tx[$name]}
            UP_LATENCY[i]=${old_lat[$name]}
            [ "$name" != "$previous_active" ] || ACTIVE_INDEX=$i
            continue
        fi

        if [ -n "${old_iface[$name]:-}" ]; then
            log "reconfiguring uplink ${name}"
            uplink_rules_del "${old_iface[$name]}"
            uplink_stop_raw "${old_iface[$name]}" "${old_pid[$name]}"
            rebuilt=$((rebuilt + 1))
        else
            log "adding uplink ${name}"
            added=$((added + 1))
        fi

        # A node that has just been (re)built has not proven anything yet, so it
        # has to earn its way back in through the normal recovery threshold
        # instead of immediately stealing the route from a working uplink.
        UP_HEALTHY[i]=false
        UP_OKS[i]=0
        UP_FAILS[i]=0

        if uplink_setup "$i"; then
            uplink_rules_add "${UP_IFACE[$i]}"
        fi
    done

    log "reload applied: ${added} added, ${rebuilt} reconfigured, ${removed} removed"

    # The kill switch REJECT rule must stay at the bottom of FORWARD even after
    # rules were added and removed around it, and the ip rule may have been lost
    # with a deleted interface.
    uplinks_routing_base

    uplinks_refresh_health
    local want
    want=$(uplinks_select)
    if [ "$want" -ge 0 ]; then
        uplink_activate "$want" force
    else
        ACTIVE_INDEX=-1
        ip route del default table "$CASCADE_TABLE" 2>/dev/null || true
        log "no healthy uplink after the reload; the kill switch keeps clients blocked"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Monitor
# ---------------------------------------------------------------------------

# Runs in the foreground of the entrypoint so that it owns every amneziawg-go
# process it starts: only the parent of a process can wait for it, and reaping is
# what keeps a long-lived reload cycle from filling the container with zombies.
uplinks_monitor() {
    local want now next_health=0
    local seen_request seen_mtime requested mtime

    seen_request=$(uplinks_reload_request_id)
    seen_mtime=$(uplinks_config_mtime)
    RELOAD_ID=$seen_request

    while :; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "the ${AWG_IFACE} process exited"
            return 1
        fi

        now=$(date -u +%s)
        requested=$(uplinks_reload_request_id)
        mtime=$(uplinks_config_mtime)

        if [ "$requested" != "$seen_request" ] || [ "$mtime" != "$seen_mtime" ]; then
            if [ "$requested" != "$seen_request" ]; then
                log "reload requested (id ${requested})"
            else
                log "the exit node list changed on disk"
            fi
            seen_request=$requested
            seen_mtime=$mtime
            uplinks_reload || true
            RELOAD_ID=$requested
            uplinks_write_state
            next_health=$((now + CASCADE_PROBE_INTERVAL))
        fi

        if [ "$now" -ge "$next_health" ]; then
            uplinks_read_control
            uplinks_refresh_health
            want=$(uplinks_select)

            if [ "$want" -ge 0 ]; then
                NO_HEALTHY_LOGGED=false
                uplink_activate "$want"
            elif [ "$NO_HEALTHY_LOGGED" = "false" ]; then
                NO_HEALTHY_LOGGED=true
                log "every uplink is down; the kill switch keeps client traffic blocked"
            fi

            uplinks_write_state
            next_health=$((now + CASCADE_PROBE_INTERVAL))
        fi

        sleep 1
    done
}
