#!/usr/bin/env bash
# Bootstraps the entry node (AmneziaWG + panel). Run on the entry server from the
# project directory.
#
#   ./scripts/bootstrap-entry.sh --endpoint-host 203.0.113.10 \
#       --cascade-endpoint 198.51.100.20:51820
#
# Writes .env if it does not exist, then builds and starts the whole stack.
# Secrets are generated locally on the server; only the admin password is printed.
set -euo pipefail

cd "$(dirname "$0")/.."

ENDPOINT_HOST=""
PORT=443
SUBNET=10.8.0.0/24
CASCADE_ENDPOINT=""
CASCADE_ADDRESS=10.77.0.2/32
HTTP_PORT=80
ENV_FILE=.env

while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint-host) ENDPOINT_HOST=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --subnet) SUBNET=$2; shift 2 ;;
        --cascade-endpoint) CASCADE_ENDPOINT=$2; shift 2 ;;
        --cascade-address) CASCADE_ADDRESS=$2; shift 2 ;;
        --http-port) HTTP_PORT=$2; shift 2 ;;
        --env-file) ENV_FILE=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

rand() { python3 -c "import random;print(random.randint($1,$2))"; }

if [ ! -f "$ENV_FILE" ]; then
    [ -n "$ENDPOINT_HOST" ] || ENDPOINT_HOST=$(curl -fsS --max-time 5 https://api.ipify.org || echo "")
    [ -n "$ENDPOINT_HOST" ] || { echo "pass --endpoint-host" >&2; exit 1; }

    S1=$(rand 15 150)
    while :; do
        S2=$(rand 15 150)
        [ "$((S1 + 56))" -ne "$S2" ] && break
    done
    readarray -t H < <(python3 -c "import random;print('\n'.join(map(str, random.sample(range(5, 2147483647), 4))))")

    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)

    cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=saucewg
IMAGE_AWG=saucewg/awg:1.0.0
IMAGE_PANEL=saucewg/panel:1.0.0
IMAGE_WEB=saucewg/web:1.0.0

PANEL_TITLE=SauceWG
PANEL_HTTP_PORT=${HTTP_PORT}
PANEL_HTTPS_PORT=8443
PANEL_SITE_ADDRESS=:80
CADDY_AUTO_HTTPS=off
DOCS_ENABLED=true
LOG_LEVEL=info

ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=$(openssl rand -hex 32)
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440

POSTGRES_DB=saucewg
POSTGRES_USER=saucewg
POSTGRES_PASSWORD=$(openssl rand -hex 24)

AWG_IFACE=awg0
AWG_PORT=${PORT}
AWG_SUBNET=${SUBNET}
AWG_MTU=1420
AWG_ENDPOINT_HOST=${ENDPOINT_HOST}
AWG_JC=$(rand 3 10)
AWG_JMIN=50
AWG_JMAX=1000
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H[0]}
AWG_H2=${H[1]}
AWG_H3=${H[2]}
AWG_H4=${H[3]}

CASCADE_ENABLED=true
CASCADE_IFACE=awg1
CASCADE_ADDRESS=${CASCADE_ADDRESS}
CASCADE_MTU=1380
CASCADE_KEEPALIVE=25
CASCADE_KILLSWITCH=true
CASCADE_ENDPOINT=${CASCADE_ENDPOINT}
CASCADE_PEER_PUBLIC_KEY=
CASCADE_PEER_PSK=
# Must match the exit node's AWG_* obfuscation values.
CASCADE_JC=
CASCADE_JMIN=
CASCADE_JMAX=
CASCADE_S1=
CASCADE_S2=
CASCADE_H1=
CASCADE_H2=
CASCADE_H3=
CASCADE_H4=

CLIENT_DNS=1.1.1.1, 1.0.0.1
CLIENT_MTU=1280
CLIENT_ALLOWED_IPS=0.0.0.0/0, ::/0
CLIENT_KEEPALIVE=25
CLIENT_JC=0
CLIENT_JMIN=0
CLIENT_JMAX=0

COLLECTOR_INTERVAL_SECONDS=10
SYNC_INTERVAL_SECONDS=30
ONLINE_TIMEOUT_SECONDS=180
USAGE_BUCKET_MINUTES=60
USAGE_RETENTION_DAYS=90
SUBSCRIPTION_URL_PREFIX=
EOF
    chmod 600 "$ENV_FILE"
    echo "wrote $ENV_FILE"
    echo "admin password: ${ADMIN_PASSWORD}"
fi

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-saucewg.conf
sysctl -q -p /etc/sysctl.d/99-saucewg.conf

docker compose --env-file "$ENV_FILE" build
docker compose --env-file "$ENV_FILE" up -d

echo
echo "Entry node started. Uplink public key to install on the exit node:"
sleep 4
docker compose --env-file "$ENV_FILE" exec -T awg cat /etc/amnezia/amneziawg/awg1.params 2>/dev/null || true
