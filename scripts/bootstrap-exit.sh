#!/usr/bin/env bash
# Bootstraps the exit node. Run on the exit server from the project directory.
#
#   ./scripts/bootstrap-exit.sh --port 51820 --subnet 10.77.0.0/24
#
# Writes .env if it does not exist, builds the image and starts the node. Private
# keys are generated inside the container and never leave the server.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT=51820
SUBNET=10.77.0.0/24
# Every entry-node uplink lands on its own address in this subnet, so accepting the
# whole range keeps this node usable in any slot of the entry node's list.
PEER_ALLOWED_IPS=10.77.0.0/24
ENV_FILE=.env
NODE_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT=$2; shift 2 ;;
        --subnet) SUBNET=$2; shift 2 ;;
        --peer-allowed-ips) PEER_ALLOWED_IPS=$2; shift 2 ;;
        --name) NODE_NAME=$2; shift 2 ;;
        --env-file) ENV_FILE=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$NODE_NAME" ] || NODE_NAME=$(hostname -s 2>/dev/null || echo exit)

rand() { python3 -c "import random;print(random.randint($1,$2))"; }

if [ ! -f "$ENV_FILE" ]; then
    S1=$(rand 15 150)
    while :; do
        S2=$(rand 15 150)
        [ "$((S1 + 56))" -ne "$S2" ] && break
    done
    readarray -t H < <(python3 -c "import random;print('\n'.join(map(str, random.sample(range(5, 2147483647), 4))))")

    cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=saucewg-exit
IMAGE_AWG=saucewg/awg:1.1.0

AWG_IFACE=awg0
AWG_PORT=${PORT}
AWG_SUBNET=${SUBNET}
AWG_MTU=1420

# AmneziaWG legacy obfuscation. Mirror these into the entry node's CASCADE_* vars.
AWG_JC=$(rand 3 10)
AWG_JMIN=50
AWG_JMAX=1000
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H[0]}
AWG_H2=${H[1]}
AWG_H3=${H[2]}
AWG_H4=${H[3]}

# Filled in once the entry node publishes its uplink public key.
AWG_PEER_PUBLIC_KEY=
AWG_PEER_PSK=
AWG_PEER_ALLOWED_IPS=${PEER_ALLOWED_IPS}
WAN_IFACE=
EOF
    chmod 600 "$ENV_FILE"
    echo "wrote $ENV_FILE"
fi

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-saucewg.conf
sysctl -q -p /etc/sysctl.d/99-saucewg.conf

docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" build
docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" up -d

echo
sleep 4

PARAMS=$(docker compose -f docker-compose.exit.yml --env-file "$ENV_FILE" \
    exec -T awg cat /etc/amnezia/amneziawg/awg0.params)

PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo "REPLACE_WITH_THIS_SERVERS_IP")

# Emit the entry that goes straight into the entry node's config/exit-nodes.json.
echo "Exit node started. Add this object to the entry node's exit-nodes.json:"
echo
printf '%s\n' "$PARAMS" | awk -v name="$NODE_NAME" -v ip="$PUBLIC_IP" '
    BEGIN { FS = "=" }
    { p[$1] = $2 }
    END {
        printf "  {\n"
        printf "    \"name\": \"%s\",\n", name
        printf "    \"endpoint\": \"%s:%s\",\n", ip, p["SERVER_PORT"]
        printf "    \"public_key\": \"%s\",\n", p["SERVER_PUBLIC_KEY"]
        printf "    \"priority\": 10,\n"
        printf "    \"s1\": %s,\n", p["SERVER_S1"]
        printf "    \"s2\": %s,\n", p["SERVER_S2"]
        printf "    \"h1\": %s,\n", p["SERVER_H1"]
        printf "    \"h2\": %s,\n", p["SERVER_H2"]
        printf "    \"h3\": %s,\n", p["SERVER_H3"]
        printf "    \"h4\": %s\n", p["SERVER_H4"]
        printf "  }\n"
    }'
echo
echo "Then install the uplink public key the entry node prints for this slot into"
echo "AWG_PEER_PUBLIC_KEY here and restart:"
echo "  docker compose -f docker-compose.exit.yml up -d --force-recreate"
