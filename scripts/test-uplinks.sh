#!/usr/bin/env bash
# Exercises the node container's live-reload logic without root, Docker or a TUN
# device: every system call is stubbed and each uplink "process" is a sleep. What
# is under test is the bookkeeping that decides whether a running tunnel survives
# an edit to the exit node list — the part that, when it is wrong, silently drops
# the uplink carrying client traffic.
#
#   ./scripts/test-uplinks.sh
#
# Needs bash 4+ (associative arrays) and jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'cleanup' EXIT

export AWG_CONFIG_DIR="$WORK/config"
export AWG_SOCKET_DIR="$WORK/run"
export AWG_IFACE=awg0
export AWG_SUBNET=10.8.0.0/24
export CASCADE_NODES_FILE="$WORK/exit-nodes.json"
export CASCADE_DIRECT_FILE="$WORK/direct-routes.json"
export CASCADE_UPLINK_SUBNET=10.77.0.0/24
export UPLINK_STATE_FILE="$WORK/run/uplinks.json"
export UPLINK_CONTROL_FILE="$WORK/run/uplink-control.json"
export UPLINK_RELOAD_FILE="$WORK/run/reload.request"
export BYPASS_FILE="$WORK/bypass.json"
export BYPASS_CONFIG_FILE="$WORK/run/bypass.json"
export BYPASS_STATE_FILE="$WORK/run/bypass-state.json"
# Off until the tests that are about it, so everything before them exercises the
# same code paths it did before the bypass existed.
export BYPASS_MODE=off
export BYPASS_GROUPS=telegram
mkdir -p "$AWG_CONFIG_DIR" "$AWG_SOCKET_DIR"

# shellcheck source=../docker/awg/lib.sh
. "$ROOT/docker/awg/lib.sh"

# --- stubs -----------------------------------------------------------------
VERBOSE=${VERBOSE:-false}
log() { [ "$VERBOSE" != true ] || printf '    [awg] %s\n' "$*" >&2; }

# `ip` and `iptables` are modelled rather than swallowed: which table holds which
# route, and where the REJECT rule sits in FORWARD, is exactly what decides whether
# client traffic leaves through an exit node, through the entry node or nowhere.
ROUTES="$WORK/routes"   # table <TAB> destination <TAB> as `ip route show` would print
RULES="$WORK/rules"     # one policy rule per line
IPT="$WORK/iptables"    # table|chain|rule, in chain order
: > "$ROUTES"; : > "$RULES"; : > "$IPT"

# What the entry node's own default route looks like. Reassigned by the tests that
# move it.
FAKE_DEFAULT="default via 192.0.2.1 dev eth0"

ip() {
    local args=() x table=main i
    for x in "$@"; do
        case $x in -4|-6) ;; *) args+=("$x") ;; esac
    done
    for ((i = 0; i < ${#args[@]}; i++)); do
        [ "${args[$i]}" = table ] && table=${args[$((i + 1))]}
    done

    case "${args[0]:-}" in
        route)
            local dest=${args[2]:-} display
            case "${args[1]:-}" in
                show)
                    if [ "$dest" = default ] && [ "$table" = main ]; then
                        printf '%s\n' "$FAKE_DEFAULT"
                    else
                        awk -F'\t' -v t="$table" '$1 == t {print $3}' "$ROUTES"
                    fi
                    ;;
                replace|add)
                    # "unreachable default" names the type before the destination.
                    [ "$dest" != unreachable ] || dest=${args[3]:-}
                    display=$(printf '%s' "${args[*]:2}" | sed 's/ table [0-9]*$//')
                    ip route del "$dest" table "$table" >/dev/null 2>&1
                    printf '%s\t%s\t%s\n' "$table" "$dest" "$display" >> "$ROUTES"
                    ;;
                del)
                    awk -F'\t' -v t="$table" -v d="$dest" \
                        '!($1 == t && $2 == d)' "$ROUTES" > "$ROUTES.tmp" || true
                    mv "$ROUTES.tmp" "$ROUTES"
                    ;;
                flush)
                    awk -F'\t' -v t="$table" '$1 != t' "$ROUTES" > "$ROUTES.tmp" || true
                    mv "$ROUTES.tmp" "$ROUTES"
                    ;;
            esac
            ;;
        rule)
            local selector="${args[*]:2}"
            selector=${selector% priority *}
            case "${args[1]:-}" in
                add) printf '%s\n' "${args[*]:2}" >> "$RULES" ;;
                del)
                    awk -v s="$selector" 'index($0, s) != 1' "$RULES" > "$RULES.tmp" || true
                    mv "$RULES.tmp" "$RULES"
                    ;;
            esac
            ;;
    esac
    return 0
}

iptables() {
    local table=filter args=() key rest
    while [ $# -gt 0 ]; do
        case $1 in
            -t) table=$2; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    local op=${args[0]:-} chain=${args[1]:-}
    case $op in
        -I) rest="${args[*]:3}" ;;
        -C|-A|-D) rest="${args[*]:2}" ;;
        *) return 0 ;;
    esac
    key="${table}|${chain}|${rest}"

    case $op in
        -C) grep -Fxq -- "$key" "$IPT" || return 1 ;;
        -A) grep -Fxq -- "$key" "$IPT" || printf '%s\n' "$key" >> "$IPT" ;;
        -I)
            grep -Fxq -- "$key" "$IPT" && return 0
            # Only position 1 is ever used, and it has to land above the catch-all.
            awk -v k="$key" -v p="${table}|${chain}|" '
                !placed && index($0, p) == 1 { print k; placed = 1 }
                { print }
                END { if (!placed) print k }' "$IPT" > "$IPT.tmp"
            mv "$IPT.tmp" "$IPT"
            ;;
        -D)
            grep -Fxv -- "$key" "$IPT" > "$IPT.tmp" 2>/dev/null || true
            mv "$IPT.tmp" "$IPT"
            ;;
    esac
    return 0
}

conntrack() { :; }
ping() { return 1; }
awg() {
    case "${1:-}" in
        genkey) head -c32 /dev/urandom | base64 ;;
        pubkey) sed 's/.*/PUB-&/' ;;
        setconf) return 0 ;;
        # No handshake data, so every uplink probes as unhealthy. Health is not
        # what these tests are about.
        *) return 1 ;;
    esac
}
# Redirected so a backgrounded stub never holds this script's stdout open.
amneziawg-go() { sleep 600 >/dev/null 2>&1; }
wait_for_socket() { return 0; }
iface_up() { return 0; }

# The relay stands in for the real one, publishing the counters file it would so
# that the path from its table to uplinks.json is exercised. What it does with a
# connection is its own business and is not what these tests are about.
awg-bypass() {
    local config="" state=""
    while [ $# -gt 0 ]; do
        case $1 in
            -config) config=$2; shift 2 ;;
            -state) state=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    jq -n --argjson pid "$$" --argjson prefixes "$(jq '.map | length' "$config")" \
        --arg listen "$(jq -r .listen "$config")" \
        '{pid: $pid, listen: $listen, prefixes: $prefixes, open: 0, accepted: 0,
          via_v6: 0, via_retry: 0, failed: 0, attempts: 0, cooled: 0,
          rx_bytes: 0, tx_bytes: 0}' \
        > "$state"
    sleep 600 >/dev/null 2>&1
}

# shellcheck source=../docker/awg/uplinks.sh
. "$ROOT/docker/awg/uplinks.sh"

# --- harness ---------------------------------------------------------------
PASSED=0
FAILED=0

check() {
    local what=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        printf '  ok   %s\n' "$what"
        PASSED=$((PASSED + 1))
    else
        printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$what" "$want" "$got"
        FAILED=$((FAILED + 1))
    fi
}

layout() {
    local i out=""
    for i in "${!UP_NAME[@]}"; do out="${out}${UP_NAME[$i]}=${UP_IFACE[$i]} "; done
    printf '%s' "${out% }"
}

pids() {
    local i out=""
    for i in "${!UP_NAME[@]}"; do out="${out}${UP_NAME[$i]}:${UP_PID[$i]} "; done
    printf '%s' "${out% }"
}

pid_of() {
    local i
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_NAME[$i]}" = "$1" ] && { printf '%s' "${UP_PID[$i]}"; return; }
    done
    printf 'missing'
}

nodes() { printf '%s\n' "$1" > "$CASCADE_NODES_FILE"; }

node() {
    printf '{"name":"%s","endpoint":"%s","public_key":"KEY-%s","address":"10.77.0.%s/32","priority":%s}' \
        "$1" "$2" "$1" "$3" "$4"
}

# The same, plus the AmneziaWG generation the exit node serves.
node_v() {
    printf '{"name":"%s","endpoint":"%s","public_key":"KEY-%s","address":"10.77.0.%s/32","priority":%s,"protocol":"%s"}' \
        "$1" "$2" "$1" "$3" "$4" "$5"
}

protocol_of() {
    local i
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_NAME[$i]}" = "$1" ] && { printf '%s' "${UP_PROTOCOL[$i]}"; return; }
    done
    printf 'missing'
}

# The obfuscation parameters one uplink's generated .conf actually carries, in order.
# This is what decides which generation the far end sees.
conf_params() {
    local i iface
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_NAME[$i]}" = "$1" ] && iface=${UP_IFACE[$i]}
    done
    [ -n "${iface:-}" ] || { printf 'missing'; return; }
    sed -n 's/^\([A-Za-z0-9]*\) = .*/\1/p' "${AWG_CONFIG_DIR}/${iface}.conf" \
        | grep -Ex 'Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]' | tr '\n' ' ' | sed 's/ $//'
}

conf_value() {
    local i iface
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_NAME[$i]}" = "$1" ] && iface=${UP_IFACE[$i]}
    done
    sed -n "s/^$2 = //p" "${AWG_CONFIG_DIR}/${iface}.conf"
}

# --- routing accessors -----------------------------------------------------

# What the cascade table sends client traffic to: an uplink interface, "unreachable",
# or nothing at all (which means the lookup falls through to the entry node's own
# routes).
cascade_default() {
    local line
    line=$(awk -F'\t' -v t="$CASCADE_TABLE" '$1 == t && $2 == "default" {print $3}' "$ROUTES")
    case $line in
        "") printf 'none' ;;
        unreachable*) printf 'unreachable' ;;
        *) printf '%s' "${line##* dev }" ;;
    esac
}

# The destinations in the bypass table, sorted, plus where each is sent.
direct_table() {
    awk -F'\t' -v t="$CASCADE_DIRECT_TABLE" '$1 == t {print $2}' "$ROUTES" | sort | tr '\n' ' ' | sed 's/ $//'
}

direct_route_of() {
    awk -F'\t' -v t="$CASCADE_DIRECT_TABLE" -v d="$1" '$1 == t && $2 == d {print $3}' "$ROUTES"
}

# The routing tables client traffic is looked up in, in the order the kernel would
# consult them.
rule_tables() {
    sed -n 's/.*lookup \([0-9]*\) priority \([0-9]*\)/\2 \1/p' "$RULES" \
        | sort -n | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'
}

forward_chain() {
    sed -n 's/^filter|FORWARD|//p' "$IPT"
}

forward_last() {
    forward_chain | tail -n1
}

has_rule() {
    forward_chain | grep -Fxq -- "$1" && printf 'yes' || printf 'no'
}

has_nat() {
    sed -n 's/^nat|POSTROUTING|//p' "$IPT" | grep -Fxq -- "$1" && printf 'yes' || printf 'no'
}

routes() { printf '%s\n' "$1" > "$CASCADE_DIRECT_FILE"; }

bypass_list() { printf '%s\n' "$1" > "$BYPASS_FILE"; }

# The destinations currently redirected into the relay, sorted.
bypass_redirects() {
    sed -n "s/^nat|PREROUTING|-i awg0 -p tcp -d \([^ ]*\) -j REDIRECT.*/\1/p" "$IPT" \
        | sort | tr '\n' ' ' | sed 's/ $//'
}

# The relay publishes its counters from its own process, so there is a moment
# after it starts in which the file it publishes them to does not exist yet.
wait_for_relay_state() {
    local i=0
    while [ "$i" -lt 50 ] && [ ! -s "$BYPASS_STATE_FILE" ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

# The IPv6 counterpart the relay was handed for one prefix, or "-" for none.
bypass_target_of() {
    jq -r --arg cidr "$1" \
        '(.map[] | select(.prefix == $cidr) | (if .v6 == "" then "-" else .v6 end)) // "absent"' \
        "$BYPASS_CONFIG_FILE"
}

# Every stub tunnel, including the ones a re-parse dropped from the arrays: `wait`
# would otherwise block on a process nothing is left holding a pid for.
cleanup() {
    local running
    running=$(jobs -pr) || running=""
    # shellcheck disable=SC2086  # deliberately word-split into one argument per pid
    [ -z "$running" ] || kill $running 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK"
}

# ---------------------------------------------------------------------------

echo "1. the configured nodes come up on their own interfaces"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-de 203.0.113.31:51820 3 20)]"
uplinks_parse
uplinks_setup_all
check "interfaces are handed out in order" "eu-nl=awg1 eu-de=awg2" "$(layout)"
nl_pid=$(pid_of eu-nl)
de_pid=$(pid_of eu-de)
check "both uplinks are running" "true" \
    "$([ "$nl_pid" -gt 0 ] && [ "$de_pid" -gt 0 ] && echo true || echo false)"
check "the list came from the file" "file" "$CONFIG_SOURCE"

echo "2. adding a node leaves the running ones alone"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-de 203.0.113.31:51820 3 20),$(node eu-fr 203.0.113.9:51820 4 30)]"
uplinks_reload
check "the new node takes the next free slot" "eu-nl=awg1 eu-de=awg2 eu-fr=awg3" "$(layout)"
check "eu-nl kept its process" "$nl_pid" "$(pid_of eu-nl)"
check "eu-de kept its process" "$de_pid" "$(pid_of eu-de)"
fr_pid=$(pid_of eu-fr)

echo "3. removing a node does not renumber the survivors"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-fr 203.0.113.9:51820 4 30)]"
uplinks_reload
check "eu-fr stays on awg3" "eu-nl=awg1 eu-fr=awg3" "$(layout)"
check "eu-nl kept its process" "$nl_pid" "$(pid_of eu-nl)"
check "eu-fr kept its process" "$fr_pid" "$(pid_of eu-fr)"
check "the departed process was reaped" "gone" \
    "$(kill -0 "$de_pid" 2>/dev/null && echo alive || echo gone)"

echo "4. a new node reuses the interface number that was freed"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-fr 203.0.113.9:51820 4 30),$(node eu-pl 192.0.2.5:51820 5 40)]"
uplinks_reload
check "eu-pl takes awg2" "eu-nl=awg1 eu-fr=awg3 eu-pl=awg2" "$(layout)"
check "eu-nl is still untouched" "$nl_pid" "$(pid_of eu-nl)"
pl_pid=$(pid_of eu-pl)

echo "5. changing an endpoint rebuilds only that uplink"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-fr 203.0.113.99:51820 4 30),$(node eu-pl 192.0.2.5:51820 5 40)]"
uplinks_reload
check "eu-nl untouched" "$nl_pid" "$(pid_of eu-nl)"
check "eu-pl untouched" "$pl_pid" "$(pid_of eu-pl)"
check "eu-fr was rebuilt" "rebuilt" \
    "$([ "$(pid_of eu-fr)" != "$fr_pid" ] && echo rebuilt || echo kept)"
fr_pid=$(pid_of eu-fr)

echo "6. changing only a priority rebuilds nothing"
nodes "[$(node eu-nl 198.51.100.20:51820 2 90),$(node eu-fr 203.0.113.99:51820 4 5),$(node eu-pl 192.0.2.5:51820 5 40)]"
uplinks_reload
check "every process survived" "eu-nl:${nl_pid} eu-fr:${fr_pid} eu-pl:${pl_pid}" "$(pids)"

echo "7. an unusable list is refused instead of taking the cascade down"
before=$(layout)
nodes '{"not":"an array"}'
uplinks_reload || true
check "the running layout is unchanged" "$before" "$(layout)"
check "the reason is recorded" "the exit node list is not a JSON array" "$CONFIG_ERROR"

echo "8. an uplink whose process died is restarted"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10)]"
uplinks_reload
nl_pid=$(pid_of eu-nl)
kill "$nl_pid" 2>/dev/null || true
wait "$nl_pid" 2>/dev/null || true
uplinks_refresh_health
check "it came back with a new process" "restarted" \
    "$([ "$(pid_of eu-nl)" != "$nl_pid" ] && [ "$(pid_of eu-nl)" -gt 0 ] && echo restarted || echo dead)"

echo "9. the published state is machine readable"
# shellcheck disable=SC2034  # uplinks_write_state reads it from the caller's scope
RELOAD_ID=12345
uplinks_write_state
check "the reload id round trips" "12345" "$(jq -r .reload_id "$UPLINK_STATE_FILE")"
check "the source is published" "file" "$(jq -r .source "$UPLINK_STATE_FILE")"
check "there is no config error" "null" "$(jq -r .config_error "$UPLINK_STATE_FILE")"
check "the nodes are published" "eu-nl" "$(jq -r '.nodes[0].name' "$UPLINK_STATE_FILE")"

echo "10. an environment list overrides the file, and says so"
export CASCADE_NODES_JSON='[{"name":"from-env","endpoint":"192.0.2.9:51820","public_key":"KEYENV"}]'
uplinks_reload
uplinks_write_state
check "the environment list is in effect" "from-env" "$(jq -r '.nodes[0].name' "$UPLINK_STATE_FILE")"
check "the source says env" "env" "$(jq -r .source "$UPLINK_STATE_FILE")"
unset CASCADE_NODES_JSON

echo "11. each uplink speaks the generation its exit node asked for"
# A cascade is routinely mixed: one server on new firmware, another still on 1.0.
nodes "[$(node_v v-one 198.51.100.20:51820 2 10 1.0),$(node_v v-mid 203.0.113.31:51820 3 20 1.5),$(node_v v-two 192.0.2.5:51820 4 30 2.0),$(node v-none 192.0.2.7:51820 5 40)]"
uplinks_reload
check "1.0 is applied as asked" "1.0" "$(protocol_of v-one)"
check "1.5 is applied as asked" "1.5" "$(protocol_of v-mid)"
check "2.0 is applied as asked" "2.0" "$(protocol_of v-two)"
# An exit node installed before generations existed names none and serves 1.0.
check "an unnamed generation means 1.0" "1.0" "$(protocol_of v-none)"

echo "12. the generated config carries exactly that generation's parameters"
check "1.0 has no S3, S4 or I1" "Jc Jmin Jmax S1 S2 H1 H2 H3 H4" "$(conf_params v-one)"
check "1.5 adds I1" "Jc Jmin Jmax S1 S2 H1 H2 H3 H4 I1" "$(conf_params v-mid)"
check "2.0 adds S3, S4 and I1" "Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1" "$(conf_params v-two)"
check "the signature is a spec, not a preset name" "true" \
    "$(case "$(conf_value v-two I1)" in *'<'*) echo true ;; *) echo false ;; esac)"

echo "13. moving one exit node to another generation rebuilds only its uplink"
one_pid=$(pid_of v-one); mid_pid=$(pid_of v-mid); two_pid=$(pid_of v-two)
s1_before=$(conf_value v-one S1)
nodes "[$(node_v v-one 198.51.100.20:51820 2 10 2.0),$(node_v v-mid 203.0.113.31:51820 3 20 1.5),$(node_v v-two 192.0.2.5:51820 4 30 2.0),$(node v-none 192.0.2.7:51820 5 40)]"
uplinks_reload
check "v-one was rebuilt" "rebuilt" \
    "$([ "$(pid_of v-one)" != "$one_pid" ] && echo rebuilt || echo kept)"
check "v-mid untouched" "$mid_pid" "$(pid_of v-mid)"
check "v-two untouched" "$two_pid" "$(pid_of v-two)"
check "v-one now carries S3, S4 and I1" "Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1" "$(conf_params v-one)"
# The padding both ends already agree on is kept, so only the new parameters appear.
check "the padding it shares with the far end is kept" "$s1_before" "$(conf_value v-one S1)"

echo "14. moving back down stops advertising the newer parameters"
nodes "[$(node_v v-one 198.51.100.20:51820 2 10 1.0),$(node_v v-mid 203.0.113.31:51820 3 20 1.5),$(node_v v-two 192.0.2.5:51820 4 30 2.0),$(node v-none 192.0.2.7:51820 5 40)]"
uplinks_reload
check "S3, S4 and I1 are gone again" "Jc Jmin Jmax S1 S2 H1 H2 H3 H4" "$(conf_params v-one)"
check "and the generation is recorded as 1.0" "1.0" "$(protocol_of v-one)"

echo "15. an unusable generation falls back instead of dropping the uplink"
nodes "[$(node_v v-one 198.51.100.20:51820 2 10 3.0)]"
uplinks_reload
check "the uplink is still up" "true" "$([ "$(pid_of v-one)" -gt 0 ] && echo true || echo false)"
check "on 1.0, which every client can load" "1.0" "$(protocol_of v-one)"

echo "16. the generation reaches the panel through the state file"
nodes "[$(node_v v-one 198.51.100.20:51820 2 10 2.0),$(node v-none 192.0.2.7:51820 5 40)]"
uplinks_reload
uplinks_write_state
check "it is published per node" "2.0" \
    "$(jq -r '.nodes[] | select(.name == "v-one") | .protocol' "$UPLINK_STATE_FILE")"
check "an unnamed one is published as 1.0" "1.0" \
    "$(jq -r '.nodes[] | select(.name == "v-none") | .protocol' "$UPLINK_STATE_FILE")"
# A reload that changes nothing must not lose it: the value is only resolved when an
# uplink is built, and a kept uplink is never built again.
uplinks_reload
uplinks_write_state
check "and it survives a no-op reload" "2.0" \
    "$(jq -r '.nodes[] | select(.name == "v-one") | .protocol' "$UPLINK_STATE_FILE")"

echo "17. a healthy uplink carries client traffic through the cascade"
nodes "[$(node eu-nl 198.51.100.20:51820 2 10),$(node eu-de 203.0.113.31:51820 3 20)]"
uplinks_reload
uplinks_routing_base
UP_HEALTHY[0]=true
uplink_activate 0 force
check "the cascade table points at the active uplink" "awg1" "$(cascade_default)"
check "client traffic is looked up in the cascade table" "451" "$(rule_tables)"
check "the uplink may forward" "yes" "$(has_rule "-i awg0 -o awg1 -j ACCEPT")"
check "nothing else may" "-i awg0 -j REJECT --reject-with icmp-net-unreachable" "$(forward_last)"

echo "18. with every uplink down, the entry node carries the traffic itself"
UP_HEALTHY[0]=false; UP_HEALTHY[1]=false
uplinks_fallback
check "the cascade table has no route left" "none" "$(cascade_default)"
check "so the lookup falls through to the entry node's own" "yes" \
    "$(has_rule "-i awg0 -o eth0 -j ACCEPT")"
check "and the entry node NATs it" "yes" "$(has_nat "-s 10.8.0.0/24 -o eth0 -j MASQUERADE")"
check "the catch-all is still last" "-i awg0 -j REJECT --reject-with icmp-net-unreachable" \
    "$(forward_last)"

echo "19. a recovered uplink takes the traffic back"
UP_HEALTHY[1]=true
uplink_activate 1
check "the cascade table points at it again" "awg2" "$(cascade_default)"
check "and the entry node stops forwarding for clients" "no" \
    "$(has_rule "-i awg0 -o eth0 -j ACCEPT")"

echo "20. CASCADE_FALLBACK=block keeps the old kill switch"
CASCADE_FALLBACK=block uplinks_parse
check "the mode is resolved from the environment" "block" "$FALLBACK_MODE"
FALLBACK_ACTIVE=false
uplinks_fallback
check "the cascade table blackholes instead of falling through" "unreachable" "$(cascade_default)"
check "the entry node does not forward for clients" "no" "$(has_rule "-i awg0 -o eth0 -j ACCEPT")"

echo "21. an .env written before CASCADE_FALLBACK existed keeps its behaviour"
check "kill switch on means block" "block" \
    "$(CASCADE_KILLSWITCH=true uplinks_resolve_fallback)"
check "kill switch off means direct" "direct" \
    "$(CASCADE_KILLSWITCH=false uplinks_resolve_fallback)"
check "neither set means direct" "direct" "$(uplinks_resolve_fallback)"
check "an explicit choice wins over the old name" "direct" \
    "$(CASCADE_FALLBACK=direct CASCADE_KILLSWITCH=true uplinks_resolve_fallback)"
check "and a typo does not silently block anyone" "direct" \
    "$(CASCADE_FALLBACK=nonsense uplinks_resolve_fallback)"

echo "22. listed destinations bypass the cascade"
FALLBACK_MODE=$(uplinks_resolve_fallback)
routes '["203.0.113.0/24", "198.51.100.7", {"cidr": "192.0.2.128/25", "note": "youtube"}]'
direct_reload
check "each one is in the bypass table" "192.0.2.128/25 198.51.100.7/32 203.0.113.0/24" \
    "$(direct_table)"
check "a bare address is a single host" "198.51.100.7/32 via 192.0.2.1 dev eth0" \
    "$(direct_route_of 198.51.100.7/32)"
check "the bypass table is consulted first" "450 451" "$(rule_tables)"
check "the entry node NATs what it sends out" "yes" "$(has_nat "-s 10.8.0.0/24 -o eth0 -j MASQUERADE")"

echo "23. an address inside a range is stored as the range"
routes '["10.20.30.40/24"]'
direct_reload
check "it is masked to its network" "10.20.30.0/24" "$(direct_table)"

echo "24. a disabled entry is not routed"
routes '[{"cidr": "203.0.113.0/24", "enabled": false}, {"cidr": "198.51.100.0/24"}]'
direct_reload
check "only the enabled one is applied" "198.51.100.0/24" "$(direct_table)"

echo "25. a bad entry is skipped, the rest still apply"
routes '["203.0.113.0/24", "not-an-address", "10.0.0.0/33", "0.0.0.0/0"]'
direct_reload
check "the good one is routed" "203.0.113.0/24" "$(direct_table)"
check "the others are reported" "true" \
    "$(case "$DIRECT_ERROR" in *"skipped 3 entries"*) echo true ;; *) echo "$DIRECT_ERROR" ;; esac)"

echo "26. removing the list takes the rules down with it"
routes '[]'
direct_reload
check "the bypass table is empty" "" "$(direct_table)"
check "and clients are no longer looked up in it" "451" "$(rule_tables)"

echo "27. an unusable list keeps the routes that were working"
routes '["203.0.113.0/24"]'
direct_reload
routes '{"not":"an array"}'
direct_reload
check "the previous routes are still in place" "203.0.113.0/24" "$(direct_table)"
check "the reason is recorded" "true" \
    "$(case "$DIRECT_ERROR" in *"not a JSON array"*) echo true ;; *) echo "$DIRECT_ERROR" ;; esac)"

echo "28. the direct routes follow the entry node's own gateway"
routes '["203.0.113.0/24"]'
direct_reload
FAKE_DEFAULT="default via 192.0.2.254 dev eth1"
direct_routes_apply
check "the route is rebuilt on the new gateway" "203.0.113.0/24 via 192.0.2.254 dev eth1" \
    "$(direct_route_of 203.0.113.0/24)"
check "and the NAT moves with it" "yes" "$(has_nat "-s 10.8.0.0/24 -o eth1 -j MASQUERADE")"
check "the old NAT rule is withdrawn" "no" "$(has_nat "-s 10.8.0.0/24 -o eth0 -j MASQUERADE")"
FAKE_DEFAULT="default via 192.0.2.1 dev eth0"
direct_routes_apply

echo "29. the environment form overrides the file"
export CASCADE_DIRECT_ROUTES="8.8.8.8, 9.9.9.0/24"
direct_reload
check "both entries are applied" "8.8.8.8/32 9.9.9.0/24" "$(direct_table)"
check "the source says env" "env" "$DIRECT_SOURCE"
unset CASCADE_DIRECT_ROUTES

echo "30. all of it reaches the panel through the state file"
routes '["203.0.113.0/24", "198.51.100.7"]'
direct_reload
# shellcheck disable=SC2034  # both are read by the code under test
UP_HEALTHY[0]=false
# shellcheck disable=SC2034
FALLBACK_ACTIVE=false
FALLBACK_MODE=direct
uplinks_fallback
uplinks_write_state
check "the fallback mode is published" "direct" "$(jq -r .fallback "$UPLINK_STATE_FILE")"
check "so is the fact that it is in use" "true" "$(jq -r .fallback_active "$UPLINK_STATE_FILE")"
check "an older panel still sees a kill switch flag" "false" \
    "$(jq -r .killswitch "$UPLINK_STATE_FILE")"
check "the direct routes are published" "198.51.100.7/32 203.0.113.0/24" \
    "$(jq -r '.direct.routes | sort | join(" ")' "$UPLINK_STATE_FILE")"
check "with the count actually installed" "2" "$(jq -r .direct.applied "$UPLINK_STATE_FILE")"
check "and where they leave through" "eth0" "$(jq -r .direct.via "$UPLINK_STATE_FILE")"

echo "31. the built-in group knows which destinations to reopen, and how"
BYPASS_MODE=auto
bypass_reload
# Counted from the group itself: the table gains rows as Telegram's addresses
# change, and a test that restates its size only ever fails for that.
GROUP_SIZE=$(bypass_group_rows telegram | wc -l | tr -d ' ')
check "the relay is running" "true" "$(bypass_running && echo true || echo false)"
check "a datacenter address is translated to the same datacenter" "2001:67c:4e8:f002::a" \
    "$(bypass_target_of 149.154.167.51/32)"
check "a range with no known counterpart is dialled as itself" "-" \
    "$(bypass_target_of 91.108.4.0/22)"
check "every prefix in the group is redirected" "$GROUP_SIZE" \
    "$(bypass_redirects | wc -w | tr -d ' ')"
check "the port only listens where a client can reach it" "10.8.0.1:8646" \
    "$(jq -r .listen "$BYPASS_CONFIG_FILE")"

echo "32. an unknown group is reported without losing the known ones"
BYPASS_GROUPS="telegram,nonsense"
bypass_reload
check "the good group still applies" "true" \
    "$([ "$(jq '.map | length' "$BYPASS_CONFIG_FILE")" -gt 20 ] && echo true || echo false)"
check "the typo is named" "true" \
    "$(case "$BYPASS_ERROR" in *"no built-in bypass group named 'nonsense'"*) echo true ;; *) echo "$BYPASS_ERROR" ;; esac)"
BYPASS_GROUPS=telegram

echo "33. the operator's list adds destinations and overrides built-in ones"
bypass_list '[{"cidr": "203.0.113.0/24", "note": "some service"},
              {"cidr": "149.154.167.51/32", "v6": "2001:db8::1", "note": "moved"},
              {"cidr": "91.108.56.0/22", "enabled": false}]'
bypass_reload
check "the extra destination is redirected" "yes" \
    "$(case " $(bypass_redirects) " in *" 203.0.113.0/24 "*) echo yes ;; *) echo no ;; esac)"
check "a repeated prefix takes the operator's counterpart" "2001:db8::1" \
    "$(bypass_target_of 149.154.167.51/32)"
check "a built-in row can be switched off" "absent" "$(bypass_target_of 91.108.56.0/22)"
check "and it stops being redirected" "no" \
    "$(case " $(bypass_redirects) " in *" 91.108.56.0/22 "*) echo yes ;; *) echo no ;; esac)"

echo "34. a bad entry is skipped, the rest still apply"
bypass_list '["203.0.113.0/24", "not-an-address", "0.0.0.0/0"]'
bypass_reload
check "the good one is redirected" "yes" \
    "$(case " $(bypass_redirects) " in *" 203.0.113.0/24 "*) echo yes ;; *) echo no ;; esac)"
check "the others are reported" "true" \
    "$(case "$BYPASS_ERROR" in *"skipped 2 bypass entries"*) echo true ;; *) echo "$BYPASS_ERROR" ;; esac)"
bypass_list '[]'
bypass_reload

echo "35. in auto it is withdrawn the moment an exit node takes the traffic back"
relay_pid=$BYPASS_PID
UP_HEALTHY[0]=true
uplink_activate 0 force
check "the redirect is gone" "" "$(bypass_redirects)"
check "the relay is stopped with it" "false" "$(bypass_running && echo true || echo false)"
check "and its process was reaped" "gone" \
    "$(kill -0 "$relay_pid" 2>/dev/null && echo alive || echo gone)"

echo "36. and reinstated when the cascade drops again"
UP_HEALTHY[0]=false
FALLBACK_MODE=direct
uplinks_fallback
check "the destinations are redirected again" "true" \
    "$([ "$(bypass_redirects | wc -w | tr -d ' ')" -gt 20 ] && echo true || echo false)"
check "with the relay back up" "true" "$(bypass_running && echo true || echo false)"

echo "37. always engages it even while the cascade is carrying traffic"
BYPASS_MODE=always
UP_HEALTHY[0]=true
uplink_activate 0 force
check "the redirect stays in place" "true" \
    "$([ "$(bypass_redirects | wc -w | tr -d ' ')" -gt 20 ] && echo true || echo false)"
BYPASS_MODE=off
bypass_apply
check "off takes it down whatever the cascade is doing" "" "$(bypass_redirects)"

echo "38. all of it reaches the panel through the state file"
BYPASS_MODE=auto
# shellcheck disable=SC2034  # read by the code under test
UP_HEALTHY[0]=false
FALLBACK_MODE=direct
uplinks_fallback
wait_for_relay_state
uplinks_write_state
check "the mode is published" "auto" "$(jq -r .bypass.mode "$UPLINK_STATE_FILE")"
check "so are the groups" "telegram" "$(jq -r '.bypass.groups | join(",")' "$UPLINK_STATE_FILE")"
check "and whether it is in force right now" "true" "$(jq -r .bypass.active "$UPLINK_STATE_FILE")"
check "with the count actually redirected" "$GROUP_SIZE" "$(jq -r .bypass.applied "$UPLINK_STATE_FILE")"
check "one destination carries its counterpart" "2001:67c:4e8:f004::9" \
    "$(jq -r '.bypass.routes[] | select(.cidr == "149.154.167.99/32") | .v6' "$UPLINK_STATE_FILE")"
check "and one carries none" "null" \
    "$(jq -r '.bypass.routes[] | select(.cidr == "91.108.4.0/22") | .v6' "$UPLINK_STATE_FILE")"
check "the relay's own counters are passed through" "$GROUP_SIZE" \
    "$(jq -r '.bypass.relay.prefixes' "$UPLINK_STATE_FILE")"
check "there is nothing to warn about" "null" "$(jq -r .bypass.error "$UPLINK_STATE_FILE")"

echo "39. a relay that dies is restarted rather than left silently down"
kill "$BYPASS_PID" 2>/dev/null || true
wait "$BYPASS_PID" 2>/dev/null || true
check "it is noticed as gone" "false" "$(bypass_running && echo true || echo false)"
bypass_apply
check "and brought back" "true" "$(bypass_running && echo true || echo false)"
check "with the redirect still complete" "$GROUP_SIZE" "$(bypass_redirects | wc -w | tr -d ' ')"

echo "40. tearing the node down leaves no redirect behind"
uplinks_teardown
check "the redirect is removed" "" "$(bypass_redirects)"
check "and the relay is stopped" "false" "$(bypass_running && echo true || echo false)"

echo
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
