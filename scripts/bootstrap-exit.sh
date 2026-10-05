#!/usr/bin/env bash
# Bootstraps the exit node. Run on the exit server from the project directory.
#
#   ./scripts/bootstrap-exit.sh --port 51820 --subnet 10.77.0.0/24
#   ./scripts/bootstrap-exit.sh --protocol 1.0        # to pair with an older entry node
#
# Writes .env if it does not exist, builds the image and starts the node. Private
# keys are generated inside the container and never leave the server.
#
# This is the git-checkout path; saucewg.sh is the installer for a real deployment.
set -euo pipefail

cd "$(dirname "$0")/.."

# The obfuscation helpers come from the node image's own library, so a profile written
# here is identical to one the container would have generated for itself.
# shellcheck source=../docker/awg/lib.sh
. docker/awg/lib.sh

PORT=51820
SUBNET=10.77.0.0/24
# The IPv6 half of the link to the entry node. Empty carries IPv4 only; the prefix
# given here has to be the one the entry node has in CASCADE_UPLINK_SUBNET6.
SUBNET6=""
# Every entry-node uplink lands on its own address in this subnet, so accepting the
# whole range keeps this node usable in any slot of the entry node's list.
PEER_ALLOWED_IPS=""
ENV_FILE=.env
NODE_NAME=""
PROTOCOL=$AWG_PROTOCOL_DEFAULT
SIGNATURE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT=$2; shift 2 ;;
        --subnet) SUBNET=$2; shift 2 ;;
        --subnet6) SUBNET6=$2; shift 2 ;;
        --peer-allowed-ips) PEER_ALLOWED_IPS=$2; shift 2 ;;
        --name) NODE_NAME=$2; shift 2 ;;
        --env-file) ENV_FILE=$2; shift 2 ;;
        --protocol) PROTOCOL=$2; shift 2 ;;
        --signature) SIGNATURE=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$NODE_NAME" ] || NODE_NAME=$(hostname -s 2>/dev/null || echo exit)
case $SUBNET6 in
    auto|yes|on|true) SUBNET6=fd00:77::/64 ;;
    no|off|false) SUBNET6="" ;;
esac
# AllowedIPs is the inbound filter as well as the route, so it has to name every
# family the bridge carries or this node drops what it is sent.
if [ -z "$PEER_ALLOWED_IPS" ]; then
    PEER_ALLOWED_IPS=$SUBNET
    [ -z "$SUBNET6" ] || PEER_ALLOWED_IPS="${SUBNET}, ${SUBNET6}"
fi
PROTOCOL=$(awg_protocol "$PROTOCOL") \
    || { echo "unknown AmneziaWG generation: $PROTOCOL" >&2; exit 1; }

# The .env spellings of the parameters this generation carries. The suffixes are already
# the variable names, so no case conversion is needed — .conf spelling is emit_obfuscation's
# job, and this file is read by compose.
emit_env_obfuscation() {
    local suffix value
    for suffix in $AWG_OBF_SUFFIXES; do
        awg_protocol_has "$PROTOCOL" "$suffix" || continue
        value="AWG_${suffix}"
        printf 'AWG_%s=%s\n' "$suffix" "${!value:-}"
    done
}

if [ ! -f "$ENV_FILE" ]; then
    # generate_obfuscation fills in whatever is left empty, so a chosen preset is
    # simply the starting value for I1.
    # shellcheck disable=SC2034  # read indirectly by generate_obfuscation
    AWG_I1=$SIGNATURE
    generate_obfuscation AWG_ "$PROTOCOL" nodes

    cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=saucewg-exit
IMAGE_AWG=saucewg/awg:1.5.0

AWG_IFACE=awg0
AWG_PORT=${PORT}
AWG_SUBNET=${SUBNET}
# This node's side of the IPv6 half of the bridge. Empty carries IPv4 only.
AWG_SUBNET6=${SUBNET6}
AWG_MTU=1420

# The generation this uplink speaks. The entry node's entry for this node has to name
# the same one, and carry the S and H values below; Jc/Jmin/Jmax and I1 are the
# sender's own business and need not match.
AWG_PROTOCOL=${PROTOCOL}
$(emit_env_obfuscation)

# Filled in once the entry node publishes its uplink public key.
AWG_PEER_PUBLIC_KEY=
AWG_PEER_PSK=
AWG_PEER_ALLOWED_IPS=${PEER_ALLOWED_IPS}
WAN_IFACE=
EOF
    chmod 600 "$ENV_FILE"
    echo "wrote $ENV_FILE (AmneziaWG ${PROTOCOL})"
fi

{
    echo 'net.ipv4.ip_forward=1'
    # Only where something is going to be forwarded over it: turning IPv6
    # forwarding on also stops the host accepting router advertisements, which on a
    # VPS that gets its own address that way would take its IPv6 away.
    [ -z "$SUBNET6" ] || echo 'net.ipv6.conf.all.forwarding=1'
} > /etc/sysctl.d/99-saucewg.conf
sysctl -q -p /etc/sysctl.d/99-saucewg.conf

docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" build
docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" up -d

echo
sleep 4

PARAMS=$(docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" \
    exec -T awg cat /etc/amnezia/amneziawg/awg0.params)

PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "REPLACE_WITH_THIS_SERVERS_IP")
# Both endpoints are reported, because the entry node decides which one to dial and
# can move between them. amneziawg-go binds a socket of each family, so a server
# with IPv6 is already reachable over it. Only looked up when there is an IPv6
# route to look it up over, since the echo service otherwise just times out.
PUBLIC_IP6=""
if ip -6 route show default 2>/dev/null | grep -q .; then
    PUBLIC_IP6=$(curl -fsS -6 --max-time 5 https://api6.ipify.org 2>/dev/null || echo "")
fi

# Emit the entry that goes straight into the entry node's config/exit-nodes.json. Only
# the parameters this generation carries are listed, because a stray S3 would leave the
# entry node advertising 2.0 to a node that does not speak it.
echo "Exit node started. Add this object to the entry node's exit-nodes.json:"
echo
printf '%s\n' "$PARAMS" | jq -Rn --arg name "$NODE_NAME" --arg ip "$PUBLIC_IP" \
    --arg ip6 "$PUBLIC_IP6" --arg subnet6 "$SUBNET6" \
    --arg protocol "$PROTOCOL" --arg fields "$(awg_protocol_params "$PROTOCOL")" '
    [inputs | select(test("=")) | capture("^(?<k>[^=]+)=(?<v>.*)$")]
    | map({(.k): (.v | sub("^\u0027"; "") | sub("\u0027$"; ""))}) | add as $p
    | {name: $name,
       endpoint: "\($ip):\($p.SERVER_PORT)",
       public_key: $p.SERVER_PUBLIC_KEY,
       priority: 10,
       protocol: $protocol}
      # Bracketed, which is how amneziawg-tools wants an IPv6 endpoint written: a
      # bare address has its last group read as the port.
      + (if $ip6 == "" then {} else {endpoint6: "[\($ip6)]:\($p.SERVER_PORT)"} end)
      + (if $subnet6 == "" then {} else {subnet6: $subnet6} end)
      + ( $fields | split(" ")
          | map(select(startswith("J") | not))
          | map({(ascii_downcase): $p["SERVER_\(.)"]})
          | add
          | with_entries(select(.value != null and .value != ""))
          | with_entries(.value |= (if test("^[0-9]+$") then tonumber else . end)) )'
echo
echo "Then install the uplink public key the entry node prints for this slot into"
echo "AWG_PEER_PUBLIC_KEY here and restart:"
echo "  docker compose -f docker-compose.exit.yml up -d --force-recreate"
