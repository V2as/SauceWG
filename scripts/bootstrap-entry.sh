#!/usr/bin/env bash
# Bootstraps the entry node (AmneziaWG + panel). Run on the entry server from the
# project directory.
#
#   ./scripts/bootstrap-entry.sh --endpoint-host 203.0.113.10
#   ./scripts/bootstrap-entry.sh --protocol 1.0     # for clients on older routers
#
# Writes .env if it does not exist, then builds and starts the whole stack. Exit
# nodes are added afterwards with scripts/add-exit-node.sh — the entry node comes up
# with one unpaired uplink so it can publish the key you need for the first one.
# Secrets are generated locally on the server; only the admin password is printed.
#
# This is the git-checkout path; saucewg.sh is the installer for a real deployment.
set -euo pipefail

cd "$(dirname "$0")/.."

# The obfuscation helpers come from the node image's own library, so the profile written
# here is identical to one the container would have generated for itself.
# shellcheck source=../docker/awg/lib.sh
. docker/awg/lib.sh

ENDPOINT_HOST=""
PORT=443
SUBNET=10.8.0.0/24
UPLINK_SUBNET=10.77.0.0/24
# The IPv6 half of the link to the exit nodes. Empty carries IPv4 only.
UPLINK_SUBNET6=""
ENDPOINT_FAMILY=auto
HTTP_PORT=80
ENV_FILE=.env
PROTOCOL=$AWG_PROTOCOL_DEFAULT
SIGNATURE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint-host) ENDPOINT_HOST=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --subnet) SUBNET=$2; shift 2 ;;
        --uplink-subnet) UPLINK_SUBNET=$2; shift 2 ;;
        --uplink-subnet6) UPLINK_SUBNET6=$2; shift 2 ;;
        --endpoint-family) ENDPOINT_FAMILY=$2; shift 2 ;;
        --http-port) HTTP_PORT=$2; shift 2 ;;
        --env-file) ENV_FILE=$2; shift 2 ;;
        --protocol) PROTOCOL=$2; shift 2 ;;
        --signature) SIGNATURE=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

case $UPLINK_SUBNET6 in
    auto|yes|on|true) UPLINK_SUBNET6=fd00:77::/64 ;;
    no|off|false) UPLINK_SUBNET6="" ;;
esac
case $ENDPOINT_FAMILY in
    ''|auto|4|6) ;;
    *) echo "--endpoint-family takes auto, 4 or 6" >&2; exit 1 ;;
esac

PROTOCOL=$(awg_protocol "$PROTOCOL") \
    || { echo "unknown AmneziaWG generation: $PROTOCOL" >&2; exit 1; }

# The .env spellings of the parameters this generation carries.
emit_env_obfuscation() {
    local suffix name
    for suffix in $AWG_OBF_SUFFIXES; do
        awg_protocol_has "$PROTOCOL" "$suffix" || continue
        name="AWG_${suffix}"
        printf 'AWG_%s=%s\n' "$suffix" "${!name:-}"
    done
}

if [ ! -f "$ENV_FILE" ]; then
    [ -n "$ENDPOINT_HOST" ] || ENDPOINT_HOST=$(curl -fsS --max-time 5 https://api.ipify.org || echo "")
    [ -n "$ENDPOINT_HOST" ] || { echo "pass --endpoint-host" >&2; exit 1; }

    # shellcheck disable=SC2034  # read indirectly by generate_obfuscation
    AWG_I1=$SIGNATURE
    generate_obfuscation AWG_ "$PROTOCOL" clients

    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)

    cat > "$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=saucewg
IMAGE_AWG=saucewg/awg:1.5.1
IMAGE_PANEL=saucewg/panel:1.5.1
IMAGE_WEB=saucewg/web:1.5.1

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

# The generation clients connect with. 2.0 resists DPI best; 1.0 is what a router on
# KeeneticOS 5.0.8 or older can load. Set AWG_S3 and AWG_S4 to 0 if AmneziaVPN app
# users connect but pass no traffic — the profile stays 2.0 either way.
AWG_PROTOCOL=${PROTOCOL}
$(emit_env_obfuscation)

CASCADE_ENABLED=true
CASCADE_MTU=1380
CASCADE_KEEPALIVE=25
CASCADE_KILLSWITCH=true
# Exit nodes live in config/exit-nodes.json; add them with scripts/add-exit-node.sh.
CASCADE_NODES_FILE=/etc/amnezia/host/exit-nodes.json
CASCADE_UPLINK_SUBNET=${UPLINK_SUBNET}
# The IPv6 half of the same link, which is what lets an exit node reach the IPv6
# internet on behalf of this one. Each exit node needs the same prefix in its own
# AWG_SUBNET6 before anything comes back over it.
CASCADE_UPLINK_SUBNET6=${UPLINK_SUBNET6}
# Which endpoint to dial an exit node over when it publishes both: auto, 4 or 6.
CASCADE_ENDPOINT_FAMILY=${ENDPOINT_FAMILY}
CASCADE_PROBE_ENABLED=true
CASCADE_PROBE_TARGET=1.1.1.1
CASCADE_PROBE_TARGET6=2606:4700:4700::1111
CASCADE_PROBE_INTERVAL=10
CASCADE_PROBE_TIMEOUT=3
CASCADE_FAIL_THRESHOLD=3
CASCADE_RECOVER_THRESHOLD=2
CASCADE_HANDSHAKE_TIMEOUT=180

CLIENT_DNS=1.1.1.1, 1.0.0.1
CLIENT_MTU=1280
CLIENT_ALLOWED_IPS=0.0.0.0/0, ::/0
CLIENT_KEEPALIVE=25
CLIENT_JC=0
CLIENT_JMIN=0
CLIENT_JMAX=0
# Junk and signature packets are sender-side only, so clients may wear a different
# disguise from the server's own. Empty means "whatever the interface uses".
CLIENT_SIGNATURE=

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

mkdir -p config
[ -f config/exit-nodes.json ] || { echo '[]' > config/exit-nodes.json; chmod 600 config/exit-nodes.json; }

{
    echo 'net.ipv4.ip_forward=1'
    # Only where something is going to be forwarded over it: turning IPv6
    # forwarding on also stops the host accepting router advertisements, which on a
    # VPS that gets its own address that way would take its IPv6 away.
    [ -z "$UPLINK_SUBNET6" ] || echo 'net.ipv6.conf.all.forwarding=1'
} > /etc/sysctl.d/99-saucewg.conf
sysctl -q -p /etc/sysctl.d/99-saucewg.conf

docker compose --env-file "$ENV_FILE" build
docker compose --env-file "$ENV_FILE" up -d

sleep 6
echo
echo "Entry node started. Uplink public keys, one per configured exit node:"
docker compose --env-file "$ENV_FILE" exec -T awg jq -r \
    '.nodes[] | "  \(.name)\t\(.public_key)"' /var/run/amneziawg/uplinks.json 2>/dev/null \
    || echo "  (still starting; check the Exit nodes page in the panel)"
echo
echo "Add exit nodes with:  ./scripts/add-exit-node.sh --json '<object from bootstrap-exit.sh>'"
