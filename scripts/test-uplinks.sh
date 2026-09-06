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
export TORRENT_BLOCK_FILE="$WORK/torrent-block.json"
export TORRENT_STATE_FILE="$WORK/run/torrents.json"
mkdir -p "$AWG_CONFIG_DIR" "$AWG_SOCKET_DIR"

# shellcheck source=../docker/awg/lib.sh
. "$ROOT/docker/awg/lib.sh"

# --- stubs -----------------------------------------------------------------
VERBOSE=${VERBOSE:-false}
log() { [ "$VERBOSE" != true ] || printf '    [awg] %s\n' "$*" >&2; }

# `ip` and `iptables` are modelled rather than swallowed: which table holds which
# route, and where the REJECT rule sits in FORWARD, is exactly what decides whether
# client traffic leaves through an exit node, through the entry node or nowhere.
ROUTES="$WORK/routes"      # table <TAB> destination <TAB> as `ip route show` would print
RULES="$WORK/rules"        # one policy rule per line
IPT="$WORK/iptables"       # table|chain|rule, in chain order
IPT_CHAINS="$WORK/chains"  # table|chain, for the ones created with -N
IPT_COUNT="$WORK/counters" # rule key <US> packets, what the kernel would have counted
SETS="$WORK/ipsets"        # one file per set: address <TAB> packets <TAB> timeout
: > "$ROUTES"; : > "$RULES"; : > "$IPT"; : > "$IPT_CHAINS"; : > "$IPT_COUNT"
mkdir -p "$SETS"

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

# Which match extensions and targets this fake kernel has. The torrent filter
# probes for them and installs a different ladder depending on the answer, so the
# tests have to be able to take one away and see what is left — and put it back
# through FAKE_MATCHES_ALL, because a match quietly missing afterwards fails the
# rules of whatever runs next instead of the test that removed it.
FAKE_MATCHES_ALL="conntrack string comment connbytes set length multiport"
FAKE_MATCHES=$FAKE_MATCHES_ALL

fake_has() {
    case " $FAKE_MATCHES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# A rule naming a match this kernel does not have is refused whole, which is what
# makes a capability probe mean anything.
fake_rule_loadable() {
    local prev="" x
    for x in "$@"; do
        case $prev in
            -m) fake_has "$x" || return 1 ;;
            -j) [ "$x" != SET ] || fake_has set || return 1 ;;
        esac
        prev=$x
    done
    return 0
}

# Built-in chains are always there; the rest have to be created first.
fake_chain_exists() {
    case $2 in
        FORWARD|INPUT|OUTPUT|PREROUTING|POSTROUTING) return 0 ;;
    esac
    grep -Fxq -- "$1|$2" "$IPT_CHAINS"
}

# Per-rule packet counters, keyed the same way the rules are. Only the tests ever
# add to these — the kernel that would have is not here.
declare -A IPT_PKTS=()

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
        -N)
            fake_chain_exists "$table" "$chain" && return 1
            printf '%s|%s\n' "$table" "$chain" >> "$IPT_CHAINS"
            return 0
            ;;
        -F)
            fake_chain_exists "$table" "$chain" || return 1
            grep -Fv -- "${table}|${chain}|" "$IPT" > "$IPT.tmp" 2>/dev/null || true
            mv "$IPT.tmp" "$IPT"
            return 0
            ;;
        -X)
            fake_chain_exists "$table" "$chain" || return 1
            # A chain something still jumps to cannot be deleted, which is the
            # whole reason teardown flushes everything before it deletes anything.
            ! grep -q -- "-j ${chain}\$" "$IPT" || return 1
            grep -Fxv -- "${table}|${chain}" "$IPT_CHAINS" > "$IPT_CHAINS.tmp" 2>/dev/null || true
            mv "$IPT_CHAINS.tmp" "$IPT_CHAINS"
            return 0
            ;;
        -I) rest="${args[*]:3}" ;;
        -C|-A|-D) rest="${args[*]:2}" ;;
        *) return 0 ;;
    esac
    fake_chain_exists "$table" "$chain" || return 1
    fake_rule_loadable ${args[@]+"${args[@]}"} || return 1
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

# The counters, in the format the torrent filter parses them out of.
iptables-save() {
    local table=filter line chain rest packets
    while [ $# -gt 0 ]; do
        case $1 in -t) table=$2; shift 2 ;; *) shift ;; esac
    done
    printf '*%s\n' "$table"
    while IFS= read -r line; do
        case $line in "${table}|"*) ;; *) continue ;; esac
        rest=${line#*|}
        chain=${rest%%|*}
        rest=${rest#*|}
        packets=${IPT_PKTS[$line]:-0}
        printf '[%s:%s] -A %s %s\n' "$packets" "$((packets * 64))" "$chain" "$rest"
    done < "$IPT"
    printf 'COMMIT\n'
}

# One file per set, a line per member: address <TAB> packets <TAB> timeout.
ipset() {
    local name terse=false
    case "${1:-}" in
        create)
            fake_has set || return 1
            name=$2
            [ -f "$SETS/$name" ] || : > "$SETS/$name"
            ;;
        destroy)
            fake_has set || return 1
            [ -n "${2:-}" ] || { rm -f "$SETS"/*; return 0; }
            [ -f "$SETS/$2" ] || return 1
            rm -f "$SETS/$2"
            ;;
        add)
            fake_has set || return 1
            [ -f "$SETS/$2" ] || return 1
            printf '%s\t%s\t%s\n' "$3" "${4:-0}" "${5:-3600}" >> "$SETS/$2"
            ;;
        list)
            fake_has set || return 1
            shift
            [ "${1:-}" != -t ] || { terse=true; shift; }
            name=${1:-}
            [ -f "$SETS/$name" ] || return 1
            printf 'Name: %s\nType: hash:ip\nRevision: 5\nHeader: family inet hashsize 1024\n' "$name"
            printf 'Number of entries: %s\n' "$(wc -l < "$SETS/$name" | tr -d ' ')"
            [ "$terse" != true ] || return 0
            printf 'Members:\n'
            awk -F'\t' '{printf "%s timeout %s packets %s bytes %s\n", $1, $3, $2, $2 * 64}' \
                "$SETS/$name"
            ;;
    esac
    return 0
}

conntrack() { :; }

# Whether the far end still reaches the internet, which is the second half of a
# probe: a tunnel can be handshaking and still be carrying nothing.
FAKE_PING=fail
ping() {
    [ "$FAKE_PING" = ok ] || return 1
    printf 'rtt min/avg/max/mdev = 11.1/22.2/33.3/4.4 ms\n'
}

# When each interface last handshaked, as an epoch, keyed by interface name. An
# interface with no entry has never handshaked — which is what every test before
# the health ones relies on, health not being what they are about.
declare -A FAKE_HS=()

awg() {
    case "${1:-}" in
        genkey) head -c32 /dev/urandom | base64 ;;
        pubkey) sed 's/.*/PUB-&/' ;;
        setconf) return 0 ;;
        show)
            case "${3:-}" in
                latest-handshakes) printf 'PEER-%s\t%s\n' "${2:-}" "${FAKE_HS[${2:-}]:-0}" ;;
                transfer) printf 'PEER-%s\t0\t0\n' "${2:-}" ;;
                *) return 1 ;;
            esac
            ;;
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

# shellcheck source=../docker/awg/torrents.sh
. "$ROOT/docker/awg/torrents.sh"
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

iface_of() {
    local i
    for i in "${!UP_NAME[@]}"; do
        [ "${UP_NAME[$i]}" = "$1" ] && { printf '%s' "${UP_IFACE[$i]}"; return; }
    done
    printf 'missing'
}

# One field of one node as the panel reads it out of the published state.
node_field() {
    jq -r --arg n "$1" --arg f "$2" \
        '.nodes[] | select(.name == $n) | .[$f]' "$UPLINK_STATE_FILE"
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

# --- torrent accessors -----------------------------------------------------

torrent_switch() { printf '%s\n' "$1" > "$TORRENT_BLOCK_FILE"; }

# The rules of one mangle chain, in the order the kernel would walk them.
mangle_chain() {
    sed -n "s/^mangle|$1|//p" "$IPT"
}

# The layers that actually got a rule installed, deduplicated and sorted, which
# is what says which half of the ladder this kernel could take.
torrent_layers() {
    grep -o 'saucewg:torrent:[a-z-]*' "$IPT" | sed 's/.*://' \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
}

torrent_layer_rules() {
    grep -c -- "saucewg:torrent:$1 " "$IPT" | tr -d ' '
}

# The order the port policy is walked in: every allow has to be above the deny it
# is an exception to, or the allowlist means nothing.
torrent_strict_order() {
    mangle_chain "$TORRENT_CHAIN" | grep -o 'saucewg:torrent:[a-z-]*' | sed 's/.*://' \
        | grep -Ex 'allow|strict-tcp|strict-udp' | uniq | tr '\n' ' ' | sed 's/ $//'
}

# Where a chain is entered from, or "none".
torrent_hook_of() {
    sed -n "s/^mangle|FORWARD|\(.*\) -j $1\$/\1/p" "$IPT" | head -n1 | grep . || printf 'none'
}

torrent_chains() {
    sed -n 's/^mangle|//p' "$IPT_CHAINS" | sort | tr '\n' ' ' | sed 's/ $//'
}

# Charge packets to the one rule carrying a given fragment, the way the kernel
# would have. Named by fragment rather than by layer so that two rules of the same
# layer can be charged separately — whether those add up is the thing being tested.
hit_rule() {
    local packets=$1 fragment=$2 line
    while IFS= read -r line; do
        case $line in
            *"$fragment"*)
                IPT_PKTS[$line]=$(( ${IPT_PKTS[$line]:-0} + packets ))
                return 0 ;;
        esac
    done < "$IPT"
    return 1
}

# A client the guard caught, as the ipset would be holding it.
caught() { ipset add "$TORRENT_CLIENT_SET" "$1" "$2" "${3:-86000}"; }

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

echo "41. with nothing set anywhere, no torrent rule exists"
torrent_reload
check "nothing is blocked" "off" "$TORRENT_MODE"
check "and it says nobody asked" "none" "$TORRENT_SOURCE"
check "no chain was created" "" "$(torrent_chains)"
check "and forwarding is untouched" "none" "$(torrent_hook_of "$TORRENT_CHAIN")"

echo "42. the panel's file turns the guard on"
torrent_switch '{"enabled": true, "mode": "on"}'
torrent_reload
check "the mode is read from the file" "on" "$TORRENT_MODE"
check "every chain is in place" \
    "SAUCEWG_TORRENT SAUCEWG_TORRENT_CUT SAUCEWG_TORRENT_HIT SAUCEWG_TORRENT_IN SAUCEWG_TORRENT_SCAN" \
    "$(torrent_chains)"
check "client traffic enters the ladder" "-i awg0" "$(torrent_hook_of "$TORRENT_CHAIN")"
check "and what comes back is checked too" "-o awg0" "$(torrent_hook_of "$TORRENT_IN_CHAIN")"
check "discovery, the wire and the replies are all covered" \
    "dht dns handshake lsd metainfo peer pex port scan tracker utp" "$(torrent_layers)"
check "the probe chain was cleaned up after itself" "gone" \
    "$(case " $(torrent_chains) " in *PROBE*) echo kept ;; *) echo gone ;; esac)"

echo "43. a hit blacklists the peer, notes the client and drops"
check "the blacklist is consulted before anything else" \
    "-m set --match-set saucewg-torrent-peers dst -m comment --comment saucewg:torrent:peer -j SAUCEWG_TORRENT_HIT" \
    "$(mangle_chain "$TORRENT_CHAIN" | head -n1)"
check "a hit remembers the peer" "yes" \
    "$(mangle_chain "$TORRENT_HIT_CHAIN" | grep -Fxq -- '-j SET --add-set saucewg-torrent-peers dst --exist' && echo yes || echo no)"
check "and who was talking to it" "yes" \
    "$(mangle_chain "$TORRENT_HIT_CHAIN" | grep -Fxq -- '-j SET --add-set saucewg-torrent-clients src --exist' && echo yes || echo no)"
check "before dropping the packet" "-j DROP" "$(mangle_chain "$TORRENT_HIT_CHAIN" | tail -n1)"
# A DNS query for a tracker goes to a resolver: blacklisting it would take the
# client off the internet entirely.
check "a cut never blacklists the destination" "yes" \
    "$(mangle_chain "$TORRENT_CUT_CHAIN" | grep -Fq -- 'add-set saucewg-torrent-peers' && echo no || echo yes)"
check "though it still notes the client" "yes" \
    "$(mangle_chain "$TORRENT_CUT_CHAIN" | grep -Fq -- 'add-set saucewg-torrent-clients src' && echo yes || echo no)"

echo "44. standard leaves ordinary ports alone, strict closes them"
check "nothing is refused for its port alone" "0" "$(torrent_layer_rules strict-tcp)"
torrent_switch '{"enabled": true, "mode": "strict"}'
torrent_reload
check "strict is in force" "strict" "$TORRENT_MODE"
check "outbound TCP is now default-deny" "1" "$(torrent_layer_rules strict-tcp)"
check "and so is UDP" "1" "$(torrent_layer_rules strict-udp)"
check "each deny sits below the ports it excepts" "allow strict-tcp allow strict-udp" \
    "$(torrent_strict_order)"
check "and the signature layers are still there" "true" \
    "$([ "$(torrent_layer_rules dht)" -gt 0 ] && echo true || echo false)"

echo "45. a long allowlist becomes several rules rather than being truncated"
check "fifteen ports fit in one" "20,21,22,25,53,80,110,143,443,465,587,853,993,995,1935" \
    "$(torrent_port_chunks "$TORRENT_TCP_PORTS" | head -n1)"
check "a range costs two of them" "3128,3478,5222,5223,5228:5230,8080,8443" \
    "$(torrent_port_chunks "$TORRENT_TCP_PORTS" | tail -n1)"
check "and no port is lost in the split" "22" \
    "$(torrent_port_chunks "$TORRENT_TCP_PORTS" | tr ',' '\n' | wc -l | tr -d ' ')"

echo "46. a tick that changes nothing does not rebuild sixty rules"
iptables -t mangle -D "$TORRENT_SCAN_CHAIN" -p udp --dport 6771 \
    -m comment --comment saucewg:torrent:lsd -j "$TORRENT_CUT_CHAIN"
torrent_apply
check "the ladder is left exactly as it was" "1" "$(torrent_layer_rules lsd)"
torrent_switch '{"enabled": true, "mode": "on"}'
torrent_reload
check "but a change to the mode rebuilds all of it" "2" "$(torrent_layer_rules lsd)"

echo "47. a hook lost to somebody else's flush is put back"
iptables -t mangle -D FORWARD -i awg0 -j "$TORRENT_CHAIN"
check "it is noticed as gone" "none" "$(torrent_hook_of "$TORRENT_CHAIN")"
check "and reported while it is" "true" \
    "$(case "$(torrent_error)" in *"nothing is being sent through them"*) echo true ;; *) echo "$(torrent_error)" ;; esac)"
torrent_apply
check "the next tick reinstates it" "-i awg0" "$(torrent_hook_of "$TORRENT_CHAIN")"
check "and there is nothing left to warn about" "" "$(torrent_error)"

echo "48. what it caught reaches the panel"
hit_rule 4 '9:get_peers'
hit_rule 6 '13:announce_peer'
hit_rule 7 '0000041727101980'
hit_rule 900 'saucewg:torrent:scan '
ipset add "$TORRENT_PEER_SET" 198.51.100.9 3 3600
ipset add "$TORRENT_PEER_SET" 203.0.113.7 5 3600
caught 10.8.0.5 40
caught 10.8.0.9 12
torrent_write_state
check "the rules of one layer add up" "10" "$(jq -r .blocked.dht "$TORRENT_STATE_FILE")"
check "each layer is reported on its own" "7" "$(jq -r .blocked.tracker "$TORRENT_STATE_FILE")"
# `scan` is the rule traffic passes through on its way to being inspected, so
# counting it would report the whole node as blocked torrents.
check "the total counts what died, not what passed" "17" "$(jq -r .blocked.total "$TORRENT_STATE_FILE")"
check "the size of the blacklist is published" "2" "$(jq -r .peers "$TORRENT_STATE_FILE")"
check "the worst client is named first" "10.8.0.5" "$(jq -r '.clients[0].address' "$TORRENT_STATE_FILE")"
check "with what it cost them" "40" "$(jq -r '.clients[0].packets' "$TORRENT_STATE_FILE")"
check "the mode is published" "on" "$(jq -r .mode "$TORRENT_STATE_FILE")"
check "and where it was decided" "file" "$(jq -r .source "$TORRENT_STATE_FILE")"
check "so is what this kernel could actually do" "true" \
    "$(jq -r .capabilities.string "$TORRENT_STATE_FILE")"
check "with nothing to warn about" "null" "$(jq -r .error "$TORRENT_STATE_FILE")"

echo "49. an unusable file keeps the guard that is already up"
torrent_switch 'not json at all'
torrent_reload
check "the mode is unchanged" "on" "$TORRENT_MODE"
check "and the rules are still in force" "-i awg0" "$(torrent_hook_of "$TORRENT_CHAIN")"
check "the reason is recorded" "true" \
    "$(case "$(torrent_error)" in *"not a JSON object"*) echo true ;; *) echo "$(torrent_error)" ;; esac)"

echo "50. an unknown mode blocks the standard way rather than nothing"
torrent_switch '{"enabled": true, "mode": "paranoid-extreme"}'
torrent_reload
check "the standard mode is in force" "on" "$TORRENT_MODE"
check "and the typo is named" "true" \
    "$(case "$(torrent_error)" in *"is not one of on or strict"*) echo true ;; *) echo "$(torrent_error)" ;; esac)"

echo "51. switching it off takes every rule and both sets with it"
torrent_switch '{"enabled": false, "mode": "strict"}'
torrent_reload
check "nothing is blocked" "off" "$TORRENT_MODE"
check "no chain is left behind" "" "$(torrent_chains)"
check "nothing is sent through them any more" "" \
    "$(sed -n 's/^mangle|FORWARD|//p' "$IPT" | grep SAUCEWG || true)"
check "and the blacklist is gone with them" "gone" \
    "$(ipset list -t "$TORRENT_PEER_SET" >/dev/null 2>&1 && echo kept || echo gone)"
# The mode the operator chose survives being switched off, so turning it back on
# does not silently drop them to standard.
check "the chosen mode is still on file" "strict" "$(jq -r .mode "$TORRENT_BLOCK_FILE")"

echo "52. a kernel without the string match blocks what it can, and says which half"
FAKE_MATCHES="comment connbytes set multiport"
torrent_switch '{"enabled": true, "mode": "on"}'
torrent_reload
check "the signature layers are gone" "peer port" "$(torrent_layers)"
check "the default ports are still refused" "2" "$(torrent_layer_rules port)"
check "the operator is told what they got" "true" \
    "$(case "$(torrent_error)" in *"no iptables string match"*) echo true ;; *) echo "$(torrent_error)" ;; esac)"
check "and the panel sees it as a missing capability" "false" \
    "$(torrent_write_state; jq -r .capabilities.string "$TORRENT_STATE_FILE")"
torrent_switch '{"enabled": false}'
torrent_reload
FAKE_MATCHES=$FAKE_MATCHES_ALL

echo "53. the environment overrides the panel, and says so"
export TORRENT_BLOCK=strict
torrent_reload
check "the operator's setting wins over the file" "strict" "$TORRENT_MODE"
check "and the panel is told the switch is not its own" "env" "$TORRENT_SOURCE"
export TORRENT_BLOCK=nonsense
torrent_reload
check "a typo blocks nothing rather than everything" "off" "$TORRENT_MODE"
check "and is reported" "true" \
    "$(case "$(torrent_error)" in *"is not one of off, on or strict"*) echo true ;; *) echo "$(torrent_error)" ;; esac)"
unset TORRENT_BLOCK

echo "55. the route follows the handshake, not the other way round"
nodes "[$(node hs-one 198.51.100.20:51820 2 10)]"
uplinks_reload
uplinks_routing_base
hs_iface=$(iface_of hs-one)
FAKE_PING=ok
FAKE_HS[$hs_iface]=$(date +%s)
# Two good probes: a node that has just been built has to earn its way back in.
uplinks_refresh_health
uplinks_refresh_health
uplink_activate 0
uplinks_write_state
check "a handshaking uplink carries traffic" "$hs_iface" "$(cascade_default)"
check "and is published as healthy" "true" "$(node_field hs-one healthy)"

echo "56. a handshake that stops is a failover, not a slow one"
FAKE_HS[$hs_iface]=$(( $(date +%s) - 21600 ))
uplinks_refresh_health
uplinks_refresh_health
check "two missed probes do not move the route" "true" "${UP_HEALTHY[0]}"
uplinks_refresh_health
check "the third does" "false" "${UP_HEALTHY[0]}"
uplinks_fallback
check "with nothing else to fall back on, the entry node takes over" "none" "$(cascade_default)"

echo "57. a verdict that outlived its handshake is not published as a verdict"
# The monitor stops evaluating health — wedged, or killed while the container
# stays up — and the last verdict it wrote stays in place. This is the state that
# had the panel reporting an exit node as connected six hours after its last
# handshake: the flag says healthy, the timestamp beside it says otherwise.
UP_HEALTHY[0]=true
UP_HS[0]=$(( $(date +%s) - 21600 ))
uplinks_write_state
check "an hours-old handshake is published as down" "false" "$(node_field hs-one healthy)"
hs_age=$(( $(date +%s) - $(node_field hs-one last_handshake) ))
check "beside the handshake it was judged against" "true" \
    "$([ "$hs_age" -gt 21000 ] && echo true || echo false)"
check "and the rule the panel should apply to it" "180" \
    "$(jq -r .handshake_timeout "$UPLINK_STATE_FILE")"
check "including how long failover itself may take" "30" \
    "$(jq -r .failover_seconds "$UPLINK_STATE_FILE")"

# The hysteresis keeps a node up through CASCADE_FAIL_THRESHOLD bad probes on
# purpose, so within that window a healthy verdict and an overdue handshake agree.
# Contradicting the container there would fail a node over one missed keepalive.
UP_HS[0]=$(( $(date +%s) - CASCADE_HANDSHAKE_TIMEOUT - 5 ))
uplinks_write_state
check "a handshake inside the failover window is left alone" "true" "$(node_field hs-one healthy)"

echo "58. a handshake that is not a timestamp is not a handshake"
# `awg show` printing anything unexpected — a warning, a partial line while the
# interface is rebuilt — must not read as "recent enough".
FAKE_HS[$hs_iface]="(none)"
uplinks_refresh_health
check "it counts as never having handshaked" "0" "${UP_HS[0]}"
uplinks_write_state
check "and the node is published as down" "false" "$(node_field hs-one healthy)"
FAKE_PING=fail

echo "59. tearing the node down leaves no torrent rule behind"
torrent_switch '{"enabled": true, "mode": "strict"}'
torrent_reload
check "the guard is up" "-i awg0" "$(torrent_hook_of "$TORRENT_CHAIN")"
uplinks_teardown
check "the chains are gone" "" "$(torrent_chains)"
check "and so is every rule they held" "" "$(grep -c 'saucewg:torrent' "$IPT" | grep -v '^0$' || true)"

echo
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
