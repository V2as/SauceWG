#!/usr/bin/env bash
# Multiple exit-node uplinks with health-based failover.
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
# rewrites that one route when a better uplink is available.

UPLINK_STATE_FILE=${UPLINK_STATE_FILE:-/var/run/amneziawg/uplinks.json}
UPLINK_CONTROL_FILE=${UPLINK_CONTROL_FILE:-/var/run/amneziawg/uplink-control.json}

CASCADE_IFACE_PREFIX=${CASCADE_IFACE_PREFIX:-awg}
CASCADE_IFACE_OFFSET=${CASCADE_IFACE_OFFSET:-1}
CASCADE_NODES_FILE=${CASCADE_NODES_FILE:-/etc/amnezia/exit-nodes.json}
CASCADE_UPLINK_SUBNET=${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}

CASCADE_PROBE_ENABLED=${CASCADE_PROBE_ENABLED:-true}
CASCADE_PROBE_TARGET=${CASCADE_PROBE_TARGET:-1.1.1.1}
CASCADE_PROBE_INTERVAL=${CASCADE_PROBE_INTERVAL:-10}
CASCADE_PROBE_TIMEOUT=${CASCADE_PROBE_TIMEOUT:-3}
CASCADE_FAIL_THRESHOLD=${CASCADE_FAIL_THRESHOLD:-3}
CASCADE_RECOVER_THRESHOLD=${CASCADE_RECOVER_THRESHOLD:-2}
CASCADE_HANDSHAKE_TIMEOUT=${CASCADE_HANDSHAKE_TIMEOUT:-180}

# Parallel arrays, one slot per configured exit node.
UP_NAME=(); UP_IFACE=(); UP_ENDPOINT=(); UP_PEERKEY=(); UP_PSK=(); UP_ADDR=()
UP_PRIO=(); UP_MTU=(); UP_KEEPALIVE=()
UP_JC=(); UP_JMIN=(); UP_JMAX=(); UP_S1=(); UP_S2=(); UP_H1=(); UP_H2=(); UP_H3=(); UP_H4=()
UP_PUBKEY=(); UP_HEALTHY=(); UP_FAILS=(); UP_OKS=(); UP_LATENCY=(); UP_HS=(); UP_RX=(); UP_TX=()

ACTIVE_INDEX=-1
UPLINK_MODE=auto
UPLINK_PIN=""
NO_HEALTHY_LOGGED=false

uplink_slug() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

uplink_count() {
    printf '%s' "${#UP_NAME[@]}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Emits the exit-node list as a JSON array, whichever way the operator supplied it.
uplinks_source_json() {
    if [ -n "${CASCADE_NODES_JSON:-}" ]; then
        printf '%s' "$CASCADE_NODES_JSON"
        return
    fi
    if [ -f "$CASCADE_NODES_FILE" ]; then
        cat "$CASCADE_NODES_FILE"
        return
    fi
    # Fall back to the single-uplink variables so an existing .env keeps working.
    if [ -n "${CASCADE_ENDPOINT:-}" ] || [ -n "${CASCADE_PEER_PUBLIC_KEY:-}" ]; then
        jq -n \
            --arg name "${CASCADE_NAME:-exit-1}" \
            --arg endpoint "${CASCADE_ENDPOINT:-}" \
            --arg key "${CASCADE_PEER_PUBLIC_KEY:-}" \
            --arg psk "${CASCADE_PEER_PSK:-}" \
            --arg address "${CASCADE_ADDRESS:-}" \
            --arg jc "${CASCADE_JC:-}" --arg jmin "${CASCADE_JMIN:-}" --arg jmax "${CASCADE_JMAX:-}" \
            --arg s1 "${CASCADE_S1:-}" --arg s2 "${CASCADE_S2:-}" \
            --arg h1 "${CASCADE_H1:-}" --arg h2 "${CASCADE_H2:-}" \
            --arg h3 "${CASCADE_H3:-}" --arg h4 "${CASCADE_H4:-}" \
            '[{name: $name, endpoint: $endpoint, public_key: $key, preshared_key: $psk,
               address: $address, priority: 10,
               jc: $jc, jmin: $jmin, jmax: $jmax, s1: $s1, s2: $s2,
               h1: $h1, h2: $h2, h3: $h3, h4: $h4}]'
        return
    fi
    printf '[]'
}

# Fills the UP_* arrays. Interfaces are handed out in list order, so reordering the
# list renames interfaces — keys are stored per node name and survive that.
uplinks_parse() {
    local json idx=0 base
    json=$(uplinks_source_json)
    printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 \
        || die "the exit node list must be a JSON array"

    base=${CASCADE_UPLINK_SUBNET%%/*}
    base=${base%.*}

    # Fields are joined with US (0x1f) rather than tabs: `read` treats tab as IFS
    # whitespace and would collapse the runs of empty optional fields, shifting
    # every later column.
    local name endpoint peerkey psk addr prio mtu keepalive jc jmin jmax s1 s2 h1 h2 h3 h4
    while IFS=$'\x1f' read -r name endpoint peerkey psk addr prio mtu keepalive \
        jc jmin jmax s1 s2 h1 h2 h3 h4; do
        [ -n "$name" ] || name="exit-$((idx + 1))"

        UP_NAME[idx]=$name
        UP_IFACE[idx]="${CASCADE_IFACE_PREFIX}$((idx + CASCADE_IFACE_OFFSET))"
        UP_ENDPOINT[idx]=$endpoint
        UP_PEERKEY[idx]=$peerkey
        UP_PSK[idx]=$psk
        # Each uplink terminates on its own address inside the shared uplink subnet.
        UP_ADDR[idx]=${addr:-${base}.$((idx + 2))/32}
        UP_PRIO[idx]=${prio:-$((idx + 1))}
        UP_MTU[idx]=${mtu:-${CASCADE_MTU:-1380}}
        UP_KEEPALIVE[idx]=${keepalive:-${CASCADE_KEEPALIVE:-25}}
        UP_JC[idx]=$jc; UP_JMIN[idx]=$jmin; UP_JMAX[idx]=$jmax
        UP_S1[idx]=$s1; UP_S2[idx]=$s2
        UP_H1[idx]=$h1; UP_H2[idx]=$h2; UP_H3[idx]=$h3; UP_H4[idx]=$h4

        UP_PUBKEY[idx]=""
        UP_HEALTHY[idx]=true
        UP_FAILS[idx]=0
        UP_OKS[idx]=0
        UP_LATENCY[idx]=""
        UP_HS[idx]=0
        UP_RX[idx]=0
        UP_TX[idx]=0

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
            (.jc | s), (.jmin | s), (.jmax | s),
            (.s1 | s), (.s2 | s),
            (.h1 | s), (.h2 | s), (.h3 | s), (.h4 | s)
        ] | join("\u001f")')

    # Nothing configured yet: bring up one unpaired uplink anyway so the entry node
    # publishes a public key to pair the first exit node with, and so the kill
    # switch is already in force.
    if [ "$idx" -eq 0 ]; then
        log "no exit node is configured; starting a single unpaired uplink"
        UP_NAME[0]="exit-1"
        UP_IFACE[0]="${CASCADE_IFACE_PREFIX}${CASCADE_IFACE_OFFSET}"
        UP_ENDPOINT[0]=""
        UP_PEERKEY[0]=""
        UP_PSK[0]=""
        UP_ADDR[0]="${base}.2/32"
        UP_PRIO[0]=1
        UP_MTU[0]=${CASCADE_MTU:-1380}
        UP_KEEPALIVE[0]=${CASCADE_KEEPALIVE:-25}
        UP_JC[0]=""; UP_JMIN[0]=""; UP_JMAX[0]=""
        UP_S1[0]=""; UP_S2[0]=""
        UP_H1[0]=""; UP_H2[0]=""; UP_H3[0]=""; UP_H4[0]=""
        UP_PUBKEY[0]=""
        UP_HEALTHY[0]=false
        UP_FAILS[0]=0
        UP_OKS[0]=0
        UP_LATENCY[0]=""
        UP_HS[0]=0
        UP_RX[0]=0
        UP_TX[0]=0
    fi
}

# ---------------------------------------------------------------------------
# Interfaces
# ---------------------------------------------------------------------------

uplink_json_obfuscation() {
    local i=$1 suffix=$2
    case "$suffix" in
        JC)   printf '%s' "${UP_JC[$i]}" ;;
        JMIN) printf '%s' "${UP_JMIN[$i]}" ;;
        JMAX) printf '%s' "${UP_JMAX[$i]}" ;;
        S1)   printf '%s' "${UP_S1[$i]}" ;;
        S2)   printf '%s' "${UP_S2[$i]}" ;;
        H1)   printf '%s' "${UP_H1[$i]}" ;;
        H2)   printf '%s' "${UP_H2[$i]}" ;;
        H3)   printf '%s' "${UP_H3[$i]}" ;;
        H4)   printf '%s' "${UP_H4[$i]}" ;;
    esac
}

uplink_setup() {
    local i=$1
    local name=${UP_NAME[$i]} iface=${UP_IFACE[$i]}
    local slug keyfile parfile priv conf suffix supplied saved

    slug=$(uplink_slug "$name")
    keyfile="${AWG_CONFIG_DIR}/uplink-${slug}.key"
    parfile="${AWG_CONFIG_DIR}/uplink-${slug}.params"

    unset UPLINK_JC UPLINK_JMIN UPLINK_JMAX UPLINK_S1 UPLINK_S2 \
          UPLINK_H1 UPLINK_H2 UPLINK_H3 UPLINK_H4
    params_load "$parfile"

    if [ -f "$keyfile" ]; then
        priv=$(cat "$keyfile")
    else
        priv=$(awg_genkey)
        log "generated a private key for uplink ${name}"
    fi
    store_secret "$keyfile" "$priv"

    # An explicit value in the node list wins, then whatever was persisted on an
    # earlier start, and only then a freshly generated profile.
    for suffix in JC JMIN JMAX S1 S2 H1 H2 H3 H4; do
        supplied=$(uplink_json_obfuscation "$i" "$suffix")
        saved="UPLINK_${suffix}"
        if [ -n "$supplied" ]; then
            printf -v "NODE_${suffix}" '%s' "$supplied"
        else
            printf -v "NODE_${suffix}" '%s' "${!saved:-}"
        fi
    done
    generate_obfuscation "NODE_"

    UP_PUBKEY[i]=$(awg_pubkey "$priv")

    conf="${AWG_CONFIG_DIR}/${iface}.conf"
    {
        echo "[Interface]"
        echo "PrivateKey = ${priv}"
        emit_obfuscation "NODE_"
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

    amneziawg-go -f "$iface" &
    PIDS+=("$!")
    wait_for_socket "$iface"
    awg setconf "$iface" "$conf"
    iface_up "$iface" "${UP_ADDR[$i]}" "${UP_MTU[$i]}"

    # shellcheck disable=SC2034  # params_store reads these by name
    {
        UPLINK_NAME=$name
        UPLINK_IFACE=$iface
        UPLINK_PUBLIC_KEY=${UP_PUBKEY[$i]}
        UPLINK_PEER_PUBLIC_KEY=${UP_PEERKEY[$i]}
        UPLINK_ENDPOINT=${UP_ENDPOINT[$i]}
        UPLINK_ADDRESS=${UP_ADDR[$i]}
        UPLINK_JC=$NODE_JC; UPLINK_JMIN=$NODE_JMIN; UPLINK_JMAX=$NODE_JMAX
        UPLINK_S1=$NODE_S1; UPLINK_S2=$NODE_S2
        UPLINK_H1=$NODE_H1; UPLINK_H2=$NODE_H2; UPLINK_H3=$NODE_H3; UPLINK_H4=$NODE_H4
    }
    params_store "$parfile" \
        UPLINK_NAME UPLINK_IFACE UPLINK_PUBLIC_KEY UPLINK_PEER_PUBLIC_KEY \
        UPLINK_ENDPOINT UPLINK_ADDRESS \
        UPLINK_JC UPLINK_JMIN UPLINK_JMAX UPLINK_S1 UPLINK_S2 \
        UPLINK_H1 UPLINK_H2 UPLINK_H3 UPLINK_H4

    log "uplink ${name} up on ${iface} (${UP_ADDR[$i]}) towards ${UP_ENDPOINT[$i]:-<unpaired>} (pub ${UP_PUBKEY[$i]})"
}

uplinks_setup_all() {
    local i
    for i in "${!UP_NAME[@]}"; do
        ip link del "${UP_IFACE[$i]}" 2>/dev/null || true
        uplink_setup "$i"
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

# Rules that apply to every uplink. Only the default route inside CASCADE_TABLE
# decides which one actually carries client traffic.
uplinks_routing_base() {
    local i iface

    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_TABLE" 2>/dev/null || true
    ip rule add from "$AWG_SUBNET" lookup "$CASCADE_TABLE" priority "$CASCADE_RULE_PRIORITY"

    for i in "${!UP_NAME[@]}"; do
        iface=${UP_IFACE[$i]}
        iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE
        iptables -C FORWARD -i "$AWG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD 1 -i "$AWG_IFACE" -o "$iface" -j ACCEPT
        iptables -C FORWARD -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD 1 -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
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

uplink_activate() {
    local i=$1
    local previous=$ACTIVE_INDEX

    ip route replace default dev "${UP_IFACE[$i]}" table "$CASCADE_TABLE"
    ACTIVE_INDEX=$i

    if [ "$previous" -ge 0 ]; then
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
    local i
    for i in "${!UP_NAME[@]}"; do
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${UP_NAME[$i]}" "${UP_IFACE[$i]}" "${UP_ENDPOINT[$i]}" "${UP_ADDR[$i]}" \
            "${UP_PRIO[$i]}" "${UP_PUBKEY[$i]}" "${UP_PEERKEY[$i]}" \
            "${UP_HEALTHY[$i]}" "$is_active" \
            "${UP_HS[$i]}" "${UP_LATENCY[$i]}" "${UP_RX[$i]}" "${UP_TX[$i]}"
    done | jq -R -s \
        --arg mode "$UPLINK_MODE" \
        --arg pin "$UPLINK_PIN" \
        --arg active "$active_name" \
        --argjson now "$(date -u +%s)" \
        --argjson killswitch "$([ "${CASCADE_KILLSWITCH:-true}" = "true" ] && echo true || echo false)" '
        {
            updated_at: $now,
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
                    tx_bytes: (.[12] | tonumber)
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

uplinks_monitor() {
    local want
    while :; do
        uplinks_read_control
        uplinks_refresh_health
        want=$(uplinks_select)

        if [ "$want" -ge 0 ]; then
            NO_HEALTHY_LOGGED=false
            if [ "$want" -ne "$ACTIVE_INDEX" ]; then
                uplink_activate "$want"
            fi
        elif [ "$NO_HEALTHY_LOGGED" = "false" ]; then
            NO_HEALTHY_LOGGED=true
            log "every uplink is down; the kill switch keeps client traffic blocked"
        fi

        uplinks_write_state
        sleep "$CASCADE_PROBE_INTERVAL"
    done
}
