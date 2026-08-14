#!/usr/bin/env bash
# Manages the entry node's exit node list (config/exit-nodes.json).
#
#   ./scripts/add-exit-node.sh --name eu-de --endpoint 203.0.113.31:51820 \
#       --public-key 'Abc…=' --s1 96 --s2 40 --h1 1 --h2 2 --h3 3 --h4 4
#
#   ./scripts/add-exit-node.sh --json '{"name":"eu-de", …}'   # paste from bootstrap-exit.sh
#   ./scripts/add-exit-node.sh --json - < node.json
#   ./scripts/add-exit-node.sh --remove eu-de
#   ./scripts/add-exit-node.sh --list
#
# Adding a node restarts the node container, which briefly interrupts client traffic.
set -euo pipefail

cd "$(dirname "$0")/.."

LIST_FILE=${LIST_FILE:-config/exit-nodes.json}
UPLINK_SUBNET=${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}
RELOAD=true
ACTION=add
NAME="" ENDPOINT="" PUBLIC_KEY="" PSK="" PRIORITY="" ADDRESS="" JSON=""
S1="" S2="" H1="" H2="" H3="" H4="" JC="" JMIN="" JMAX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME=$2; shift 2 ;;
        --endpoint) ENDPOINT=$2; shift 2 ;;
        --public-key) PUBLIC_KEY=$2; shift 2 ;;
        --psk) PSK=$2; shift 2 ;;
        --priority) PRIORITY=$2; shift 2 ;;
        --address) ADDRESS=$2; shift 2 ;;
        --s1) S1=$2; shift 2 ;;
        --s2) S2=$2; shift 2 ;;
        --h1) H1=$2; shift 2 ;;
        --h2) H2=$2; shift 2 ;;
        --h3) H3=$2; shift 2 ;;
        --h4) H4=$2; shift 2 ;;
        --jc) JC=$2; shift 2 ;;
        --jmin) JMIN=$2; shift 2 ;;
        --jmax) JMAX=$2; shift 2 ;;
        --json) JSON=$2; shift 2 ;;
        --remove) ACTION=remove; NAME=$2; shift 2 ;;
        --list) ACTION=list; shift ;;
        --file) LIST_FILE=$2; shift 2 ;;
        --no-reload) RELOAD=false; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

mkdir -p "$(dirname "$LIST_FILE")"
[ -f "$LIST_FILE" ] || echo '[]' > "$LIST_FILE"
jq -e 'type == "array"' "$LIST_FILE" >/dev/null 2>&1 \
    || { echo "$LIST_FILE is not a JSON array" >&2; exit 1; }

if [ "$ACTION" = "list" ]; then
    jq -r '.[] | "\(.priority // 100)\t\(.name)\t\(.endpoint // "-")"' "$LIST_FILE" \
        | sort -n | awk 'BEGIN { print "PRIO\tNAME\tENDPOINT" } { print }'
    exit 0
fi

reload() {
    [ "$RELOAD" = "true" ] || return 0
    echo
    echo "restarting the node container…"
    docker compose up -d --force-recreate awg
    sleep 6
    echo
    echo "Uplink public keys — install each on the matching exit node as AWG_PEER_PUBLIC_KEY:"
    docker compose exec -T awg jq -r \
        '.nodes[] | "  \(.name)\t\(.public_key)"' /var/run/amneziawg/uplinks.json 2>/dev/null \
        || echo "  (the node is still starting; check the Exit nodes page in the panel)"
}

if [ "$ACTION" = "remove" ]; then
    [ -n "$NAME" ] || { echo "--remove needs a node name" >&2; exit 1; }
    jq -e --arg n "$NAME" 'any(.[]; .name == $n)' "$LIST_FILE" >/dev/null \
        || { echo "no exit node named $NAME" >&2; exit 1; }
    jq --arg n "$NAME" 'map(select(.name != $n))' "$LIST_FILE" > "${LIST_FILE}.tmp"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
    echo "removed $NAME from $LIST_FILE"
    reload
    exit 0
fi

# --- add -------------------------------------------------------------------

if [ -n "$JSON" ]; then
    if [ "$JSON" = "-" ]; then
        JSON=$(cat)
    fi
    NODE=$(printf '%s' "$JSON" | jq -e '.' 2>/dev/null) \
        || { echo "--json did not contain a valid JSON object" >&2; exit 1; }
    NAME=$(printf '%s' "$NODE" | jq -r '.name // ""')
else
    [ -n "$NAME" ] || { echo "--name is required" >&2; exit 1; }
    [ -n "$ENDPOINT" ] || { echo "--endpoint is required (host:port)" >&2; exit 1; }
    [ -n "$PUBLIC_KEY" ] || { echo "--public-key is required" >&2; exit 1; }
    NODE=$(jq -n \
        --arg name "$NAME" --arg endpoint "$ENDPOINT" --arg key "$PUBLIC_KEY" --arg psk "$PSK" \
        --arg s1 "$S1" --arg s2 "$S2" --arg h1 "$H1" --arg h2 "$H2" --arg h3 "$H3" --arg h4 "$H4" \
        --arg jc "$JC" --arg jmin "$JMIN" --arg jmax "$JMAX" '
        def num: if . == "" then null else tonumber end;
        {name: $name, endpoint: $endpoint, public_key: $key}
        + (if $psk  == "" then {} else {preshared_key: $psk} end)
        + (if $s1   == "" then {} else {s1: ($s1 | num)} end)
        + (if $s2   == "" then {} else {s2: ($s2 | num)} end)
        + (if $h1   == "" then {} else {h1: ($h1 | num)} end)
        + (if $h2   == "" then {} else {h2: ($h2 | num)} end)
        + (if $h3   == "" then {} else {h3: ($h3 | num)} end)
        + (if $h4   == "" then {} else {h4: ($h4 | num)} end)
        + (if $jc   == "" then {} else {jc: ($jc | num)} end)
        + (if $jmin == "" then {} else {jmin: ($jmin | num)} end)
        + (if $jmax == "" then {} else {jmax: ($jmax | num)} end)')
fi

[ -n "$NAME" ] || { echo "the node needs a name" >&2; exit 1; }
if jq -e --arg n "$NAME" 'any(.[]; .name == $n)' "$LIST_FILE" >/dev/null 2>&1; then
    echo "an exit node named $NAME already exists in $LIST_FILE" >&2
    exit 1
fi

# Pin an address now so removing a node later does not renumber the survivors.
if [ -z "$ADDRESS" ] && ! printf '%s' "$NODE" | jq -e 'has("address")' >/dev/null; then
    PREFIX=${UPLINK_SUBNET%%/*}
    PREFIX=${PREFIX%.*}
    for host in $(seq 2 254); do
        if ! jq -e --arg a "${PREFIX}.${host}/32" 'any(.[]; .address == $a)' "$LIST_FILE" >/dev/null; then
            ADDRESS="${PREFIX}.${host}/32"
            break
        fi
    done
    [ -n "$ADDRESS" ] || { echo "no free address left in $UPLINK_SUBNET" >&2; exit 1; }
fi

if [ -z "$PRIORITY" ] && ! printf '%s' "$NODE" | jq -e 'has("priority")' >/dev/null; then
    # Append below every existing node so the current exit keeps carrying traffic.
    PRIORITY=$(jq '[.[].priority // 100] | (max // 0) + 10' "$LIST_FILE")
fi

jq --argjson node "$NODE" \
   --arg address "$ADDRESS" \
   --arg priority "$PRIORITY" '
    . + [$node
         + (if $address  == "" then {} else {address: $address} end)
         + (if $priority == "" then {} else {priority: ($priority | tonumber)} end)]
    ' "$LIST_FILE" > "${LIST_FILE}.tmp"
mv "${LIST_FILE}.tmp" "$LIST_FILE"
chmod 600 "$LIST_FILE"

echo "added $NAME to $LIST_FILE"
jq -r --arg n "$NAME" '.[] | select(.name == $n) | "  address  \(.address)\n  priority \(.priority)\n  endpoint \(.endpoint)"' "$LIST_FILE"
reload
