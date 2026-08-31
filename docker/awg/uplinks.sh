#!/usr/bin/env bash
# Multiple exit-node uplinks with health-based failover and live reconfiguration.
#
# Every configured exit node gets its own AmneziaWG interface, its own persistent
# private key and its own obfuscation profile. All of them stay up and keep
# handshaking, so a failover is a single route swap rather than a tunnel rebuild.
#
# Client traffic is steered entirely with policy routing, in two tables consulted in
# this order:
#
#     ip rule from <client subnet> lookup 450   # destinations that bypass the cascade
#     ip rule from <client subnet> lookup 451   # everything else
#
#     table 450   one route per direct prefix, out of the entry node's own interface
#     table 451   default dev <active uplink>
#
# A destination on the direct list matches in table 450 and leaves through the entry
# node itself; anything else finds nothing there, falls through to table 451 and goes
# to an exit node. When no exit node is usable, CASCADE_FALLBACK decides what happens
# to table 451: `direct` empties it so the lookup carries on to the main table and the
# entry node carries the traffic, `block` fills it with an unreachable route.
#
# The monitor loop re-evaluates health every CASCADE_PROBE_INTERVAL seconds and
# rewrites that one route when a better uplink is available. It also watches the
# exit node list and the direct route list and applies changes in place — only the
# interfaces that actually changed are rebuilt, so adding an exit node never disturbs
# the one currently carrying client traffic.

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

# Destinations that bypass the cascade. Lower priority number than the cascade rule,
# so this table is consulted first and a listed prefix wins over the default route.
CASCADE_DIRECT_FILE=${CASCADE_DIRECT_FILE:-/etc/amnezia/host/direct-routes.json}
CASCADE_DIRECT_TABLE=${CASCADE_DIRECT_TABLE:-450}
CASCADE_DIRECT_RULE_PRIORITY=${CASCADE_DIRECT_RULE_PRIORITY:-450}

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
# The id of the last reload request the monitor finished applying. Whoever wrote
# the request polls for it in uplinks.json to know the change went live.
RELOAD_ID=0
CONFIG_ERROR=""
# Where the exit node list was read from on the last parse: file, env, legacy-env or
# none. Published so the panel can warn when its writes are being overridden.
CONFIG_SOURCE="file"

# What happens to client traffic while no exit node can carry it: `direct` lets the
# entry node carry it, `block` drops it. Resolved from configuration once here and
# again on every reload, so the mode can be changed without recreating the container.
FALLBACK_MODE=direct
# Whether that is happening right now.
FALLBACK_ACTIVE=false

# Destinations routed past the cascade, canonicalised to `network/bits`.
DIRECT_PREFIXES=()
DIRECT_SOURCE=none
DIRECT_ERROR=""
DIRECT_APPLIED=0
# The entry node's own way out, as an `ip route` next hop, and the interface it uses.
# Kept from the last apply so a DHCP lease change can be noticed and followed.
DIRECT_NEXTHOP=""
DIRECT_WAN=""
# The interface the entry node's NAT and forwarding rules currently name, so they can
# be moved rather than duplicated if it changes.
DIRECT_RULES_IFACE=""

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

# CASCADE_KILLSWITCH is the old spelling of this choice and only had the two states
# "block" and "leak". It is still honoured when CASCADE_FALLBACK is unset, so an .env
# written before this existed keeps behaving the way its author asked for: a node that
# was told to block on failure goes on blocking until someone says otherwise.
uplinks_resolve_fallback() {
    case $(printf '%s' "${CASCADE_FALLBACK:-}" | tr '[:upper:]' '[:lower:]') in
        direct|entry) printf 'direct'; return 0 ;;
        block|blocked|killswitch) printf 'block'; return 0 ;;
        '') ;;
        *)
            log "CASCADE_FALLBACK=${CASCADE_FALLBACK} is not one of direct|block; using direct"
            printf 'direct'
            return 0
            ;;
    esac
    case $(printf '%s' "${CASCADE_KILLSWITCH:-}" | tr '[:upper:]' '[:lower:]') in
        true|1|yes|on) printf 'block' ;;
        *) printf 'direct' ;;
    esac
}

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

    FALLBACK_MODE=$(uplinks_resolve_fallback)
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
    # publishes a public key to pair the first exit node with, and so the fallback —
    # blocking or direct — is already in force rather than starting later.
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
# Direct routes
# ---------------------------------------------------------------------------

# Turns one list entry into either {ok: "network/bits"} or {bad: "<as written>"}.
#
# Entries are accepted as bare strings or as objects, and a bare address means a /32,
# so a list can be pasted from anywhere that emits prefixes. The address is masked to
# its network — the kernel rejects 10.0.0.1/24 as a route, and the operator meant the
# range. A /0 is refused: it would take every destination off the cascade, which is
# what CASCADE_FALLBACK is for.
#
# Shared with the bypass list, which reads prefixes written the same way.
readonly CIDR_JQ='
def entry:
    if type == "object" then with_entries(.key |= ascii_downcase)
    else {cidr: (. | tostring)} end;
def text:
    ((.cidr // .prefix // .network // .subnet // .ip // .address // "") | tostring)
    | gsub("^\\s+|\\s+$"; "");
def canonical:
    . as $raw
    | (if test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?$") then . else "" end) as $ok
    | if $ok == "" then {bad: $raw}
      else
        ($ok | split("/")) as $parts
        | (if ($parts | length) == 2 then ($parts[1] | tonumber) else 32 end) as $bits
        | ($parts[0] | split(".") | map(tonumber)) as $o
        | if $bits < 1 or $bits > 32 or ([$o[] | select(. > 255)] | length) > 0
          then {bad: $raw}
          else
            ($o[0] * 16777216 + $o[1] * 65536 + $o[2] * 256 + $o[3]) as $addr
            | (pow(2; 32 - $bits) | floor) as $size
            | ($addr - ($addr % $size)) as $net
            | {ok: "\(($net / 16777216) | floor).\((($net % 16777216) / 65536) | floor).\((($net % 65536) / 256) | floor).\($net % 256)/\($bits)"}
          end
      end;
'

readonly DIRECT_JQ="${CIDR_JQ}"'
map(entry)
| map(select(if has("enabled") then .enabled != false else true end))
| map(text)
| map(select(length > 0))
| map(canonical)[]
| if has("ok") then "ok\u001f\(.ok)" else "bad\u001f\(.bad)" end'

direct_config_source() {
    if [ -n "${CASCADE_DIRECT_ROUTES:-}" ]; then
        printf 'env'
    elif [ -f "$CASCADE_DIRECT_FILE" ]; then
        printf 'file'
    else
        printf 'none'
    fi
}

# The environment form is a plain list — "1.2.3.0/24, 5.6.7.8" — because that is what
# fits in an .env; the file form is the JSON the panel writes.
direct_source_json() {
    case $(direct_config_source) in
        env) printf '%s' "$CASCADE_DIRECT_ROUTES" | jq -R -s 'split("[,;[:space:]]+"; "") | map(select(length > 0))' ;;
        file) cat "$CASCADE_DIRECT_FILE" 2>/dev/null || printf '[]' ;;
        *) printf '[]' ;;
    esac
}

# Fills DIRECT_PREFIXES. A malformed entry is dropped and reported rather than taken
# as a reason to discard the rest: one bad line in a list of a thousand prefixes
# should not put every other destination back on the cascade unannounced.
direct_parse() {
    local json kind value bad=0 first=""

    DIRECT_SOURCE=$(direct_config_source)
    DIRECT_ERROR=""
    json=$(direct_source_json 2>/dev/null) || json=""
    [ -n "$json" ] || json='[]'

    if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        DIRECT_ERROR="the direct route list is not a JSON array; keeping the routes that are already applied"
        log "direct routes: $DIRECT_ERROR"
        return 1
    fi

    DIRECT_PREFIXES=()
    while IFS=$'\x1f' read -r kind value; do
        case $kind in
            ok) DIRECT_PREFIXES+=("$value") ;;
            bad)
                bad=$((bad + 1))
                [ -n "$first" ] || first=$value
                ;;
        esac
    done < <(printf '%s' "$json" | jq -r "$DIRECT_JQ" 2>/dev/null)

    if [ "$bad" -gt 0 ]; then
        DIRECT_ERROR="skipped ${bad} entr$([ "$bad" -eq 1 ] && printf 'y' || printf 'ies') that are not IPv4 prefixes, starting with '${first}'"
        log "direct routes: $DIRECT_ERROR"
    fi
    return 0
}

# The interface the entry node reaches the internet through, and the next hop to use
# for it. A route in table 450 cannot say "look this up in the main table", so it has
# to name the gateway itself — and re-read it every time, because a DHCP lease change
# moves it and the direct prefixes would otherwise keep pointing at a dead gateway.
direct_wan_iface() {
    local iface=${WAN_IFACE:-}
    [ -n "$iface" ] || iface=$(wan_iface 2>/dev/null) || iface=""
    printf '%s' "$iface"
}

direct_nexthop() {
    local nexthop
    nexthop=$(wan_nexthop 2>/dev/null) || nexthop=""
    if [ -n "${WAN_IFACE:-}" ]; then
        case " $nexthop " in
            *" dev ${WAN_IFACE} "*) ;;
            *) nexthop="dev ${WAN_IFACE}" ;;
        esac
    fi
    printf '%s' "$nexthop"
}

# Writes DIRECT_PREFIXES into their own routing table, adding and removing only what
# changed — a full rewrite on every tick would break the connections of prefixes that
# did not. One table lookup covers any number of prefixes, which is why this is a
# table and not an `ip rule` per entry.
direct_routes_apply() {
    local prefix desired=" " keep=" " nexthop applied=0

    nexthop=$(direct_nexthop)
    if [ -n "$DIRECT_NEXTHOP" ] && [ "$nexthop" != "$DIRECT_NEXTHOP" ]; then
        log "direct routes: the entry node's route out changed (${DIRECT_NEXTHOP} -> ${nexthop:-none}); rebuilding"
        ip route flush table "$CASCADE_DIRECT_TABLE" 2>/dev/null || true
    fi
    DIRECT_NEXTHOP=$nexthop
    DIRECT_WAN=$(direct_wan_iface)

    for prefix in ${DIRECT_PREFIXES[@]+"${DIRECT_PREFIXES[@]}"}; do
        desired="${desired}${prefix} "
    done

    while read -r prefix; do
        [ -n "$prefix" ] || continue
        case $prefix in */*) ;; *) prefix="${prefix}/32" ;; esac
        case "$desired" in
            *" ${prefix} "*) keep="${keep}${prefix} " ;;
            *) ip route del "$prefix" table "$CASCADE_DIRECT_TABLE" 2>/dev/null || true ;;
        esac
    done < <(ip -4 route show table "$CASCADE_DIRECT_TABLE" 2>/dev/null | awk 'NF {print $1}')

    if [ -n "$nexthop" ]; then
        for prefix in ${DIRECT_PREFIXES[@]+"${DIRECT_PREFIXES[@]}"}; do
            case "$keep" in
                *" ${prefix} "*)
                    applied=$((applied + 1))
                    continue
                    ;;
            esac
            # shellcheck disable=SC2086  # the next hop is deliberately several words
            if ip route replace "$prefix" $nexthop table "$CASCADE_DIRECT_TABLE" 2>/dev/null; then
                applied=$((applied + 1))
            fi
        done
    elif [ "${#DIRECT_PREFIXES[@]}" -gt 0 ]; then
        log "direct routes: the entry node has no default route of its own; ${#DIRECT_PREFIXES[@]} prefix(es) stay on the cascade"
    fi
    DIRECT_APPLIED=$applied

    # The rule is what makes the table consulted at all, and it is only worth having
    # while something is in the table.
    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_DIRECT_TABLE" 2>/dev/null || true
    if [ "$applied" -gt 0 ]; then
        ip rule add from "$AWG_SUBNET" lookup "$CASCADE_DIRECT_TABLE" \
            priority "$CASCADE_DIRECT_RULE_PRIORITY" 2>/dev/null || true
        log "direct routes: ${applied} prefix(es) bypass the cascade via ${DIRECT_WAN:-the entry node}"
    fi

    direct_path_rules
}

# Client traffic leaves through the entry node's own interface in two cases: a
# destination on the direct list, and — with CASCADE_FALLBACK=direct — everything,
# while no exit node is usable. Both need the same NAT and forwarding rules, so they
# are installed while either applies and withdrawn when neither does.
direct_path_rules() {
    local iface needed=false
    iface=$(direct_wan_iface)

    if [ "$DIRECT_APPLIED" -gt 0 ]; then
        needed=true
    elif [ "$FALLBACK_ACTIVE" = "true" ] && [ "$FALLBACK_MODE" = "direct" ]; then
        needed=true
    fi

    if [ "$needed" = "true" ]; then
        if [ -z "$iface" ]; then
            log "cannot find the interface the entry node routes through; not installing its NAT rules"
            return 0
        fi
        if [ -n "$DIRECT_RULES_IFACE" ] && [ "$DIRECT_RULES_IFACE" != "$iface" ]; then
            path_rules_del "$DIRECT_RULES_IFACE"
        fi
        path_rules_add "$iface"
        DIRECT_RULES_IFACE=$iface
    elif [ -n "$DIRECT_RULES_IFACE" ]; then
        path_rules_del "$DIRECT_RULES_IFACE"
        DIRECT_RULES_IFACE=""
    fi
}

direct_reload() {
    direct_parse || true
    direct_routes_apply
}

# What an operator needs to be told about the direct list, if anything: entries that
# were skipped, or an entry node with no route of its own to send them out of.
direct_error() {
    if [ -z "$DIRECT_NEXTHOP" ] && [ "${#DIRECT_PREFIXES[@]}" -gt 0 ]; then
        printf 'the entry node has no default route of its own, so the direct routes are not in effect'
        return 0
    fi
    printf '%s' "$DIRECT_ERROR"
}

# ---------------------------------------------------------------------------
# Bypass
# ---------------------------------------------------------------------------
#
# Destinations a censor blocks by refusing to let a TCP connection be established
# to their IPv4, rather than by taking the route away. The entry node opens the
# outbound half itself, over the destination's IPv6 where one is known and by
# dialling its IPv4 until a handshake lands otherwise; awg-bypass does both, and
# this side decides which destinations reach it and when.
#
# The when matters as much as the what. While an exit node is carrying client
# traffic there is nothing to bypass — the flow already leaves the country — and
# redirecting it here would move it back to the entry node's own address, which
# is the exposure the cascade exists to avoid. So the default is to engage only
# while the entry node is carrying the traffic anyway.

BYPASS_MODE=${BYPASS_MODE:-auto}
BYPASS_GROUPS=${BYPASS_GROUPS:-telegram}
BYPASS_FILE=${BYPASS_FILE:-/etc/amnezia/host/bypass.json}
BYPASS_PORT=${BYPASS_PORT:-8646}
BYPASS_BIN=${BYPASS_BIN:-awg-bypass}
BYPASS_CONFIG_FILE=${BYPASS_CONFIG_FILE:-/var/run/amneziawg/bypass.json}
BYPASS_STATE_FILE=${BYPASS_STATE_FILE:-/var/run/amneziawg/bypass-state.json}
# How hard to dial an IPv4 whose handshakes are being dropped, and how long to
# wait for the IPv6 that should answer on the first try. The handshakes go out
# several at a time because the client is waiting through all of them: against an
# address losing nine SYNs in ten, six at a time is a connection in under a second
# where one at a time is ten.
BYPASS_ATTEMPTS=${BYPASS_ATTEMPTS:-96}
BYPASS_PARALLEL=${BYPASS_PARALLEL:-6}
BYPASS_ATTEMPT_TIMEOUT_MS=${BYPASS_ATTEMPT_TIMEOUT_MS:-400}
BYPASS_RETRY_BUDGET_MS=${BYPASS_RETRY_BUDGET_MS:-20000}
BYPASS_V6_TIMEOUT_MS=${BYPASS_V6_TIMEOUT_MS:-4000}
# A destination that spends a whole budget without answering is worth one
# handshake rather than a burst for a while: clients retry a failing address in
# tight loops, and the entry node pays for every attempt in ephemeral ports and
# conntrack entries.
BYPASS_COOLDOWN_MS=${BYPASS_COOLDOWN_MS:-10000}
BYPASS_COOL_AFTER=${BYPASS_COOL_AFTER:-3}

# "prefix<TAB>ipv6 counterpart<TAB>note", most specific last is fine — the relay
# sorts by prefix length itself.
BYPASS_ROWS=()
BYPASS_SOURCE=none
BYPASS_ERROR=""
# Whether the redirect is installed right now, and the port it points at.
BYPASS_ACTIVE=false
BYPASS_PID=0
BYPASS_RULES=()
# The signature of the table last handed to the relay, so an unchanged reload
# costs nothing.
BYPASS_APPLIED=""

# Destinations the built-in groups cover.
#
# The IPv6 column is only filled in where the counterpart is known to be the same
# server: an MTProto session's keys belong to one datacenter, so sending a flow to
# the wrong one is worse than not translating it at all. Everything else is listed
# without a counterpart and reached by dialling its own IPv4 persistently, which
# needs no table to stay correct.
#
# Telegram's rows are the datacenter bootstrap addresses the official clients
# ship (tdesktop's mtproto_dc_options.cpp, Telegram-iOS's seedAddressList) paired
# with the IPv6 address of the same datacenter from the same tables, plus the
# addresses t.me, api.telegram.org and the web app resolve to, each paired with
# the IPv6 of the same name.
#
# The ranges at the end carry no counterpart on purpose. Two kinds of address live
# in them: datacenter endpoints a client discovers at runtime, which cannot be
# paired without knowing which datacenter each one is — sending an MTProto session
# to the wrong one is worse than not translating it — and the media CDN, which
# publishes no IPv6 at all (cdn1..5.telesco.pe are IPv4-only). Both are reached by
# dialling their own IPv4 persistently, which is why that path carries photographs
# and video rather than only being a fallback.
#
# "prefix|ipv6 counterpart|note", one per line. The separator is not a tab because
# tab is an IFS whitespace character and `read` would collapse the two that
# surround an empty counterpart into one, silently turning the note into it.
bypass_group_rows() {
    case "$1" in
        telegram)
            cat <<'ROWS'
149.154.175.50/32|2001:b28:f23d:f001::a|telegram-dc1
149.154.175.51/32|2001:b28:f23d:f001::a|telegram-dc1
149.154.167.50/32|2001:67c:4e8:f002::a|telegram-dc2
149.154.167.51/32|2001:67c:4e8:f002::a|telegram-dc2
95.161.76.100/32|2001:67c:4e8:f002::a|telegram-dc2
149.154.175.100/32|2001:b28:f23d:f003::a|telegram-dc3
149.154.167.91/32|2001:67c:4e8:f004::a|telegram-dc4
149.154.167.92/32|2001:67c:4e8:f004::a|telegram-dc4
149.154.171.5/32|2001:b28:f23f:f005::a|telegram-dc5
91.108.56.130/32|2001:b28:f23f:f005::a|telegram-dc5
149.154.167.96/32|2001:67c:4e8:f002::b|telegram-dc2-media
149.154.164.250/32|2001:67c:4e8:f004::b|telegram-dc4-media
149.154.167.99/32|2001:67c:4e8:f004::9|telegram-web
149.154.166.110/32|2001:67c:4e8:f004::9|telegram-web
149.154.170.96/32|2001:b28:f23f:9::852:438|telegram-web-flora
149.154.175.209/32|2001:b28:f23d:8005:7:0:109:338|telegram-web-pluto
91.105.192.0/23||telegram
91.108.4.0/22||telegram
91.108.8.0/22||telegram
91.108.12.0/22||telegram
91.108.16.0/22||telegram
91.108.20.0/22||telegram
91.108.56.0/22||telegram
95.161.64.0/20||telegram
149.154.160.0/20||telegram
185.76.151.0/24||telegram
ROWS
            ;;
        *) return 1 ;;
    esac
}

bypass_groups_known() {
    printf 'telegram'
}

# The operator's own list, in the shape the panel and direct-routes.json use, with
# an optional IPv6 counterpart per entry.
readonly BYPASS_JQ="${CIDR_JQ}"'
map(entry)
| map(. + {__cidr: (. | text), __enabled: (if has("enabled") then .enabled != false else true end)})
| map(select(.__cidr | length > 0))
| map(. + {__canon: (.__cidr | canonical)})[]
| if (.__canon | has("ok"))
  then "ok\u001f\(.__canon.ok)\u001f\((.v6 // .ipv6 // "") | tostring)\u001f\(.note // "")\u001f\(.__enabled)"
  else "bad\u001f\(.__canon.bad)" end'

bypass_config_source() {
    if [ -n "${BYPASS_ROUTES:-}" ]; then
        printf 'env'
    elif [ -f "$BYPASS_FILE" ]; then
        printf 'file'
    else
        printf 'none'
    fi
}

bypass_source_json() {
    case $(bypass_config_source) in
        env) printf '%s' "$BYPASS_ROUTES" | jq -R -s 'split("[,;[:space:]]+"; "") | map(select(length > 0))' ;;
        file) cat "$BYPASS_FILE" 2>/dev/null || printf '[]' ;;
        *) printf '[]' ;;
    esac
}

# Fills BYPASS_ROWS from the enabled groups and then from the operator's list,
# which wins on any prefix it repeats and can switch a built-in row off with
# `"enabled": false` rather than by having to restate the whole group.
bypass_parse() {
    local group rows prefix v6 note enabled kind bad=0 first=""
    local -A row=() order=()
    local -a sequence=()

    BYPASS_SOURCE=$(bypass_config_source)
    BYPASS_ERROR=""
    BYPASS_ROWS=()

    for group in $(printf '%s' "${BYPASS_GROUPS:-}" | tr ',;' '  '); do
        if ! rows=$(bypass_group_rows "$group"); then
            BYPASS_ERROR="no built-in bypass group named '${group}' (known: $(bypass_groups_known))"
            log "bypass: $BYPASS_ERROR"
            continue
        fi
        while IFS='|' read -r prefix v6 note; do
            [ -n "$prefix" ] || continue
            case $prefix in '#'*) continue ;; esac
            if [ -z "${order[$prefix]:-}" ]; then
                sequence+=("$prefix")
                order[$prefix]=1
            fi
            row[$prefix]="${v6}"$'\t'"${note:-$group}"
        done <<<"$rows"
    done

    while IFS=$'\x1f' read -r kind prefix v6 note enabled; do
        case $kind in
            ok)
                if [ "$enabled" = "false" ]; then
                    unset "row[$prefix]"
                    continue
                fi
                if [ -z "${order[$prefix]:-}" ]; then
                    sequence+=("$prefix")
                    order[$prefix]=1
                fi
                row[$prefix]="${v6}"$'\t'"${note}"
                ;;
            bad)
                bad=$((bad + 1))
                [ -n "$first" ] || first=$prefix
                ;;
        esac
    done < <(bypass_source_json | jq -r "$BYPASS_JQ" 2>/dev/null)

    for prefix in ${sequence[@]+"${sequence[@]}"}; do
        [ -n "${row[$prefix]:-}" ] || continue
        BYPASS_ROWS+=("${prefix}"$'\t'"${row[$prefix]}")
    done

    if [ "$bad" -gt 0 ]; then
        BYPASS_ERROR="skipped ${bad} bypass entr$([ "$bad" -eq 1 ] && printf 'y' || printf 'ies') that are not IPv4 prefixes, starting with '${first}'"
        log "bypass: $BYPASS_ERROR"
    fi
    return 0
}

# True while the redirect should be in place. In `auto` that is exactly when
# client traffic is leaving through the entry node itself and would otherwise meet
# the filter this exists to get around.
bypass_wanted() {
    [ "${#BYPASS_ROWS[@]}" -gt 0 ] || return 1
    case "$BYPASS_MODE" in
        always|on|true) return 0 ;;
        auto)
            [ "$FALLBACK_ACTIVE" = "true" ] && [ "$FALLBACK_MODE" = "direct" ]
            return $?
            ;;
        *) return 1 ;;
    esac
}

# The address a redirect lands on: REDIRECT rewrites the destination to the
# primary address of the interface the packet arrived on, which is the one the
# server interface was brought up with. Binding there rather than to every address
# is what keeps the port off the entry node's public interface.
bypass_listen_ip() {
    local addr
    addr=$(first_host "$AWG_SUBNET")
    printf '%s' "${addr%%/*}"
}

bypass_listen_address() {
    printf '%s:%s' "$(bypass_listen_ip)" "$BYPASS_PORT"
}

# The relay's table. Only the client-facing address is bound, so the port is not
# reachable from anywhere a client cannot already reach.
bypass_write_config() {
    local tmp="${BYPASS_CONFIG_FILE}.tmp" prefix v6 note
    mkdir -p "$(dirname "$BYPASS_CONFIG_FILE")" 2>/dev/null || true

    if for prefix in ${BYPASS_ROWS[@]+"${BYPASS_ROWS[@]}"}; do
        printf '%s\n' "$prefix"
    done | jq -R -s \
        --arg listen "$(bypass_listen_address)" \
        --argjson attempts "$BYPASS_ATTEMPTS" \
        --argjson parallel "$BYPASS_PARALLEL" \
        --argjson attempt_timeout "$BYPASS_ATTEMPT_TIMEOUT_MS" \
        --argjson budget "$BYPASS_RETRY_BUDGET_MS" \
        --argjson v6_timeout "$BYPASS_V6_TIMEOUT_MS" \
        --argjson cooldown "$BYPASS_COOLDOWN_MS" \
        --argjson cool_after "$BYPASS_COOL_AFTER" '
        {
            listen: $listen,
            attempts: $attempts,
            parallel: $parallel,
            attempt_timeout_ms: $attempt_timeout,
            retry_budget_ms: $budget,
            v6_timeout_ms: $v6_timeout,
            cooldown_ms: $cooldown,
            cool_after: $cool_after,
            map: (
                split("\n") | map(select(length > 0)) | map(split("\t")) | map({
                    prefix: .[0],
                    v6: (.[1] // ""),
                    note: (.[2] // "")
                })
            )
        }' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$BYPASS_CONFIG_FILE"
        chmod 0644 "$BYPASS_CONFIG_FILE"
        return 0
    fi
    rm -f "$tmp"
    log "bypass: could not write ${BYPASS_CONFIG_FILE}"
    return 1
}

bypass_running() {
    [ "${BYPASS_PID:-0}" -gt 0 ] 2>/dev/null && kill -0 "$BYPASS_PID" 2>/dev/null
}

bypass_start() {
    bypass_running && return 0
    command -v "$BYPASS_BIN" >/dev/null 2>&1 || {
        BYPASS_ERROR="the ${BYPASS_BIN} helper is missing from this node image"
        log "bypass: $BYPASS_ERROR"
        return 1
    }
    "$BYPASS_BIN" -config "$BYPASS_CONFIG_FILE" -state "$BYPASS_STATE_FILE" &
    BYPASS_PID=$!
    log "bypass: relay started on $(bypass_listen_address) (pid ${BYPASS_PID})"
    return 0
}

bypass_stop() {
    local pid=${BYPASS_PID:-0}
    BYPASS_PID=0
    [ "$pid" -gt 0 ] 2>/dev/null || return 0
    kill "$pid" 2>/dev/null || true
    # Reaped rather than left behind: the monitor is a long-lived parent, and a
    # relay that is stopped and started as the cascade comes and goes would
    # otherwise accumulate zombies for the life of the container.
    wait "$pid" 2>/dev/null || true
    rm -f "$BYPASS_STATE_FILE"
    log "bypass: relay stopped"
}

bypass_rules_add() {
    local row prefix listen_addr
    listen_addr=$(bypass_listen_ip)

    # Traffic redirected here is delivered locally rather than forwarded, so the
    # FORWARD guard never sees it and the port needs its own way in.
    iptables -C INPUT -i "$AWG_IFACE" -p tcp -d "$listen_addr" --dport "$BYPASS_PORT" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -i "$AWG_IFACE" -p tcp -d "$listen_addr" --dport "$BYPASS_PORT" -j ACCEPT

    BYPASS_RULES=()
    for row in ${BYPASS_ROWS[@]+"${BYPASS_ROWS[@]}"}; do
        prefix=${row%%$'\t'*}
        iptables -t nat -C PREROUTING -i "$AWG_IFACE" -p tcp -d "$prefix" -j REDIRECT --to-ports "$BYPASS_PORT" 2>/dev/null \
            || iptables -t nat -A PREROUTING -i "$AWG_IFACE" -p tcp -d "$prefix" -j REDIRECT --to-ports "$BYPASS_PORT" \
            || continue
        BYPASS_RULES+=("$prefix")
    done
}

bypass_rules_del() {
    local prefix listen_addr
    listen_addr=$(bypass_listen_ip)
    for prefix in ${BYPASS_RULES[@]+"${BYPASS_RULES[@]}"}; do
        iptables -t nat -D PREROUTING -i "$AWG_IFACE" -p tcp -d "$prefix" -j REDIRECT --to-ports "$BYPASS_PORT" 2>/dev/null || true
    done
    BYPASS_RULES=()
    iptables -D INPUT -i "$AWG_IFACE" -p tcp -d "$listen_addr" --dport "$BYPASS_PORT" -j ACCEPT 2>/dev/null || true
}

# Brings what is installed into line with what the configuration and the current
# cascade state ask for. Cheap and idempotent, so it can be called from anywhere
# that changes either.
bypass_apply() {
    local signature

    if ! bypass_wanted; then
        if [ "$BYPASS_ACTIVE" = "true" ]; then
            bypass_rules_del
            bypass_stop
            BYPASS_ACTIVE=false
            BYPASS_APPLIED=""
            log "bypass: withdrawn; client traffic is on the cascade again"
        fi
        return 0
    fi

    signature=$(printf '%s\n' ${BYPASS_ROWS[@]+"${BYPASS_ROWS[@]}"})
    if [ "$BYPASS_ACTIVE" = "true" ] && [ "$signature" = "$BYPASS_APPLIED" ] && bypass_running; then
        return 0
    fi

    bypass_write_config || return 1
    if bypass_running; then
        # The relay re-reads its table on a signal, so the flows it is already
        # carrying are not interrupted by a change to the list.
        kill -HUP "$BYPASS_PID" 2>/dev/null || true
    elif ! bypass_start; then
        return 1
    fi

    if [ "$BYPASS_ACTIVE" = "true" ]; then
        bypass_rules_del
    fi
    bypass_rules_add
    BYPASS_ACTIVE=true
    BYPASS_APPLIED=$signature
    log "bypass: ${#BYPASS_RULES[@]} prefix(es) reopened through this entry node"
    # Flows that were black-holed against the filter a moment ago have conntrack
    # entries pointing straight out of eth0; without dropping them a client would
    # wait out its own TCP timeouts before trying again.
    conntrack -D -s "$AWG_SUBNET" -p tcp >/dev/null 2>&1 || true
    return 0
}

bypass_reload() {
    bypass_parse || true
    bypass_apply
}

bypass_config_mtime() {
    [ -f "$BYPASS_FILE" ] || { printf '0'; return; }
    stat -c %Y "$BYPASS_FILE" 2>/dev/null || printf '0'
}

# What the relay itself reports, which is the only place the counters exist.
bypass_runtime_json() {
    [ "$BYPASS_ACTIVE" = "true" ] || { printf 'null'; return; }
    jq -c '.' "$BYPASS_STATE_FILE" 2>/dev/null || printf 'null'
}

bypass_error() {
    if [ "$BYPASS_MODE" != "off" ] && [ "${#BYPASS_ROWS[@]}" -gt 0 ] \
        && [ "$BYPASS_ACTIVE" = "true" ] && ! bypass_running; then
        printf 'the bypass relay is not running, so the redirected destinations are unreachable'
        return 0
    fi
    printf '%s' "$BYPASS_ERROR"
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
    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_DIRECT_TABLE" 2>/dev/null || true
    ip route flush table "$CASCADE_TABLE" 2>/dev/null || true
    ip route flush table "$CASCADE_DIRECT_TABLE" 2>/dev/null || true
    [ -z "$DIRECT_RULES_IFACE" ] || path_rules_del "$DIRECT_RULES_IFACE"
    DIRECT_RULES_IFACE=""
    bypass_rules_del
    bypass_stop
    BYPASS_ACTIVE=false
    torrent_teardown
    for i in "${!UP_NAME[@]}"; do
        ip link del "${UP_IFACE[$i]}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

# NAT and forwarding for one sanctioned way out of the entry node: an uplink to an
# exit node, or the entry node's own interface when it is carrying traffic itself.
path_rules_add() {
    local iface=$1
    iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$iface" -j MASQUERADE
    # Inserted at the top so the catch-all REJECT rule stays last in the chain.
    iptables -C FORWARD -i "$AWG_IFACE" -o "$iface" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$AWG_IFACE" -o "$iface" -j ACCEPT
    iptables -C FORWARD -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$iface" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

path_rules_del() {
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
        path_rules_add "${UP_IFACE[$i]}"
    done

    # Destinations that skip the cascade, plus the NAT the entry node needs to carry
    # traffic itself — for those destinations, or for all of them while
    # CASCADE_FALLBACK=direct has no exit node left to use.
    direct_routes_apply

    # Destinations the entry node has to reach a different way than a client asked
    # for, because a filter refuses the one it asked for.
    bypass_apply

    # Client traffic may only leave through a path something above put there. The
    # rule is kept in both fallback modes: in `direct` the way out is an explicit
    # ACCEPT for the entry node's own interface, not the absence of a guard, so a
    # route appearing on some third interface still cannot carry client traffic.
    iptables -C FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null \
        || iptables -A FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable

    iptables -t mangle -C FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # What a client may not send at all, whichever of the paths above carries it.
    # Reasserted here rather than only on its own reload because this is the
    # function that puts the forwarding rules back after a reload has churned
    # them, and the guard has to survive that too.
    torrent_apply
}

# Points the client policy-routing table at one uplink. Pass "force" after a
# rebuild, when the route has to be rewritten even though the choice is unchanged.
uplink_activate() {
    local i=$1 force=${2:-}
    local previous=$ACTIVE_INDEX was_fallback=$FALLBACK_ACTIVE

    [ "$i" -ne "$previous" ] || [ "$force" = "force" ] || [ "$was_fallback" = "true" ] || return 0

    ip route replace default dev "${UP_IFACE[$i]}" table "$CASCADE_TABLE"
    ACTIVE_INDEX=$i
    FALLBACK_ACTIVE=false
    # Traffic that was leaving through the entry node no longer needs its NAT, unless
    # a direct route still uses it.
    direct_path_rules
    # Nor does it need the bypass: an exit node abroad is not being filtered, and
    # the point of the cascade is that the flow does not appear from here.
    bypass_apply

    if [ "$was_fallback" = "true" ]; then
        conntrack -D -s "$AWG_SUBNET" >/dev/null 2>&1 || true
        log "recovered: client traffic is back on the cascade via ${UP_NAME[$i]} (${UP_IFACE[$i]} -> ${UP_ENDPOINT[$i]:-<unpaired>})"
    elif [ "$previous" -ge 0 ] && [ "$previous" -ne "$i" ]; then
        # Established flows are NATed to the old exit address and would otherwise
        # black-hole until their conntrack entries expire.
        conntrack -D -s "$AWG_SUBNET" >/dev/null 2>&1 || true
        log "failover: ${UP_NAME[$previous]} -> ${UP_NAME[$i]} (${UP_IFACE[$i]} -> ${UP_ENDPOINT[$i]:-<unpaired>})"
    else
        log "active uplink: ${UP_NAME[$i]} (${UP_IFACE[$i]} -> ${UP_ENDPOINT[$i]:-<unpaired>})"
    fi
}

# No exit node can carry client traffic. Either the entry node carries it until one
# comes back, or nobody does — whichever CASCADE_FALLBACK asked for.
uplinks_fallback() {
    local previous=$ACTIVE_INDEX

    if [ "$FALLBACK_ACTIVE" = "true" ]; then
        return 0
    fi

    ACTIVE_INDEX=-1
    FALLBACK_ACTIVE=true

    if [ "$FALLBACK_MODE" = "direct" ]; then
        # The way out has to exist before traffic is pointed down it, or the packets
        # in between meet the catch-all REJECT.
        direct_path_rules
        # An empty cascade table means the lookup carries on to the main table, which
        # is the entry node's own route to the internet.
        ip route del default table "$CASCADE_TABLE" 2>/dev/null || true
        log "every exit node is down; client traffic is leaving through this entry node until one recovers"
    else
        # An unreachable route rather than an empty table: without it the lookup would
        # fall through to the main table and leave through the entry node, which is
        # the one thing this mode exists to prevent.
        ip route replace unreachable default table "$CASCADE_TABLE" 2>/dev/null \
            || ip route del default table "$CASCADE_TABLE" 2>/dev/null || true
        log "every exit node is down; blocking client traffic (CASCADE_FALLBACK=block)"
    fi

    # In `direct` the traffic now leaves from this address, so whatever is filtered
    # here is filtered for clients as well, which is what the bypass is for. In
    # `block` nothing leaves at all and it is withdrawn.
    bypass_apply

    if [ "$previous" -ge 0 ]; then
        conntrack -D -s "$AWG_SUBNET" >/dev/null 2>&1 || true
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
                path_rules_add "${UP_IFACE[$i]}"
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

    local direct_json
    direct_json=$(printf '%s\n' ${DIRECT_PREFIXES[@]+"${DIRECT_PREFIXES[@]}"} \
        | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || direct_json='[]'

    local bypass_json bypass_runtime
    bypass_json=$(printf '%s\n' ${BYPASS_ROWS[@]+"${BYPASS_ROWS[@]}"} \
        | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t")) | map({
              cidr: .[0],
              v6: (if (.[1] // "") == "" then null else .[1] end),
              note: (if (.[2] // "") == "" then null else .[2] end)
          })' 2>/dev/null) || bypass_json='[]'
    bypass_runtime=$(bypass_runtime_json)

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
        --arg fallback "$FALLBACK_MODE" \
        --arg direct_source "$DIRECT_SOURCE" \
        --arg direct_error "$(direct_error)" \
        --arg direct_wan "$DIRECT_WAN" \
        --argjson direct_routes "$direct_json" \
        --argjson direct_applied "${DIRECT_APPLIED:-0}" \
        --arg bypass_mode "$BYPASS_MODE" \
        --arg bypass_groups "$BYPASS_GROUPS" \
        --arg bypass_source "$BYPASS_SOURCE" \
        --arg bypass_error "$(bypass_error)" \
        --argjson bypass_routes "$bypass_json" \
        --argjson bypass_applied "${#BYPASS_RULES[@]}" \
        --argjson bypass_active "$([ "$BYPASS_ACTIVE" = "true" ] && echo true || echo false)" \
        --argjson bypass_runtime "$bypass_runtime" \
        --argjson fallback_active "$([ "$FALLBACK_ACTIVE" = "true" ] && echo true || echo false)" \
        --argjson now "$(date -u +%s)" '
        {
            updated_at: $now,
            reload_id: $reload,
            source: $source,
            config_error: (if $error == "" then null else $error end),
            mode: $mode,
            pinned: (if $pin == "" then null else $pin end),
            active: (if $active == "" then null else $active end),
            fallback: $fallback,
            fallback_active: $fallback_active,
            # The old name for the same choice, still published so that a panel
            # older than the container it is talking to keeps working.
            killswitch: ($fallback == "block"),
            direct: {
                source: $direct_source,
                routes: $direct_routes,
                applied: $direct_applied,
                via: (if $direct_wan == "" then null else $direct_wan end),
                error: (if $direct_error == "" then null else $direct_error end)
            },
            bypass: {
                mode: $bypass_mode,
                groups: ($bypass_groups | split("[,;[:space:]]+"; "") | map(select(length > 0))),
                source: $bypass_source,
                routes: $bypass_routes,
                applied: $bypass_applied,
                # Whether the redirect is installed right now. In `auto` this is
                # false whenever an exit node is carrying traffic, which is the
                # normal state and not a fault.
                active: $bypass_active,
                relay: $bypass_runtime,
                error: (if $bypass_error == "" then null else $bypass_error end)
            },
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

direct_config_mtime() {
    [ -f "$CASCADE_DIRECT_FILE" ] || { printf '0'; return; }
    stat -c %Y "$CASCADE_DIRECT_FILE" 2>/dev/null || printf '0'
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
        path_rules_del "${old_iface[$name]}"
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
            path_rules_del "${old_iface[$name]}"
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
            path_rules_add "${UP_IFACE[$i]}"
        fi
    done

    log "reload applied: ${added} added, ${rebuilt} reconfigured, ${removed} removed"

    # The catch-all REJECT rule must stay at the bottom of FORWARD even after rules
    # were added and removed around it, the ip rule may have been lost with a deleted
    # interface, and either destination list may be what the reload was requested for.
    direct_parse || true
    bypass_parse || true
    torrent_parse || true
    uplinks_routing_base

    uplinks_refresh_health
    local want
    want=$(uplinks_select)
    if [ "$want" -ge 0 ]; then
        uplink_activate "$want" force
    else
        # Force the fallback to be re-applied: the reload may have changed which mode
        # is in effect, and the route in the cascade table has to match it.
        FALLBACK_ACTIVE=false
        uplinks_fallback
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
    local seen_request seen_mtime seen_direct seen_bypass seen_torrent
    local requested mtime direct_mtime bypass_mtime torrent_mtime

    seen_request=$(uplinks_reload_request_id)
    seen_mtime=$(uplinks_config_mtime)
    seen_direct=$(direct_config_mtime)
    seen_bypass=$(bypass_config_mtime)
    seen_torrent=$(torrent_config_mtime)
    RELOAD_ID=$seen_request

    while :; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            log "the ${AWG_IFACE} process exited"
            return 1
        fi

        now=$(date -u +%s)
        requested=$(uplinks_reload_request_id)
        mtime=$(uplinks_config_mtime)
        direct_mtime=$(direct_config_mtime)
        bypass_mtime=$(bypass_config_mtime)
        torrent_mtime=$(torrent_config_mtime)

        if [ "$requested" != "$seen_request" ] || [ "$mtime" != "$seen_mtime" ]; then
            if [ "$requested" != "$seen_request" ]; then
                log "reload requested (id ${requested})"
            else
                log "the exit node list changed on disk"
            fi
            seen_request=$requested
            seen_mtime=$mtime
            # The reload re-reads every destination list and the torrent setting
            # too, so those edits are already applied.
            seen_direct=$direct_mtime
            seen_bypass=$bypass_mtime
            seen_torrent=$torrent_mtime
            uplinks_reload || true
            RELOAD_ID=$requested
            uplinks_write_state
            torrent_write_state
            next_health=$((now + CASCADE_PROBE_INTERVAL))
        elif [ "$direct_mtime" != "$seen_direct" ]; then
            # Only the direct list changed: the cascade itself does not need touching.
            log "the direct route list changed on disk"
            seen_direct=$direct_mtime
            direct_reload
            uplinks_write_state
        elif [ "$bypass_mtime" != "$seen_bypass" ]; then
            log "the bypass list changed on disk"
            seen_bypass=$bypass_mtime
            bypass_reload
            uplinks_write_state
        elif [ "$torrent_mtime" != "$seen_torrent" ]; then
            log "the torrent setting changed on disk"
            seen_torrent=$torrent_mtime
            torrent_reload
            torrent_write_state
        fi

        if [ "$now" -ge "$next_health" ]; then
            uplinks_read_control
            uplinks_refresh_health
            want=$(uplinks_select)

            if [ "$want" -ge 0 ]; then
                uplink_activate "$want"
            else
                uplinks_fallback
            fi

            # A DHCP lease change moves the entry node's own gateway, which the direct
            # routes name explicitly and would otherwise keep pointing at.
            if [ "$(direct_nexthop)" != "$DIRECT_NEXTHOP" ]; then
                direct_routes_apply
            fi

            # Reconciled on every tick rather than only on a state change: the
            # redirect sends traffic into a process, and a process that died would
            # otherwise leave those destinations worse off than without the bypass.
            bypass_apply
            # Same reasoning, and the counters it publishes are only as fresh as
            # the last time somebody read them off the rules.
            torrent_apply
            torrent_write_state

            uplinks_write_state
            next_health=$((now + CASCADE_PROBE_INTERVAL))
        fi

        sleep 1
    done
}
