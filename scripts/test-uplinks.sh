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
export CASCADE_UPLINK_SUBNET=10.77.0.0/24
export UPLINK_STATE_FILE="$WORK/run/uplinks.json"
export UPLINK_CONTROL_FILE="$WORK/run/uplink-control.json"
export UPLINK_RELOAD_FILE="$WORK/run/reload.request"
mkdir -p "$AWG_CONFIG_DIR" "$AWG_SOCKET_DIR"

# shellcheck source=../docker/awg/lib.sh
. "$ROOT/docker/awg/lib.sh"

# --- stubs -----------------------------------------------------------------
VERBOSE=${VERBOSE:-false}
log() { [ "$VERBOSE" != true ] || printf '    [awg] %s\n' "$*" >&2; }
ip() { :; }
iptables() { :; }
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

cleanup() {
    local i
    for i in "${!UP_NAME[@]}"; do
        if [ "${UP_PID[$i]:-0}" -gt 0 ] 2>/dev/null; then
            kill "${UP_PID[$i]}" 2>/dev/null || true
        fi
    done
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

echo
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
