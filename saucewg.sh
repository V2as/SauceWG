#!/usr/bin/env bash
# SauceWG — installer and service manager for an AmneziaWG cascade.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) install
#   bash <(curl -fsSL https://raw.githubusercontent.com/V2as/SauceWG/main/saucewg.sh) install-node
#
# The script installs itself to /usr/local/bin/saucewg, so afterwards the server is
# driven with `saucewg start|stop|restart|update|status|logs`.
#
# It is self-contained on purpose: it writes its own compose file and pulls prebuilt
# images, so a node can be provisioned on a bare server with nothing but curl. The
# generated compose files mirror docker-compose.yml and docker-compose.exit.yml in the
# repository and are validated against them in CI.
#
# Every command that produces data accepts --json and then writes exactly one JSON
# object to stdout while all human-readable progress goes to stderr, which is what
# makes the script safe to drive from a bot or a provisioning service.
set -euo pipefail

SAUCEWG_VERSION="1.3.0"

SAUCEWG_REPO="${SAUCEWG_REPO:-V2as/SauceWG}"
SAUCEWG_REF="${SAUCEWG_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${SAUCEWG_REPO}/${SAUCEWG_REF}"

APP_DIR="${SAUCEWG_DIR:-/opt/saucewg}"
CLI_PATH="${SAUCEWG_CLI_PATH:-/usr/local/bin/saucewg}"

REGISTRY="${SAUCEWG_REGISTRY:-docker.io}"
NAMESPACE="${SAUCEWG_NAMESPACE:-v2as}"
IMAGE_PREFIX="${SAUCEWG_IMAGE_PREFIX:-saucewg-}"
IMAGE_TAG="${SAUCEWG_TAG:-latest}"

ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ROLE_FILE="${APP_DIR}/.role"
CONFIG_DIR="${APP_DIR}/config"
NODES_FILE="${CONFIG_DIR}/exit-nodes.json"

JSON_OUTPUT=false
ASSUME_YES=false
QUIET=false

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[38;5;42m'; C_WARN=$'\033[38;5;214m'; C_ERR=$'\033[38;5;203m'
    C_DIM=$'\033[38;5;244m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

log()   { [ "$QUIET" = true ] || printf '%s▸%s %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
step()  { [ "$QUIET" = true ] || printf '\n%s══%s %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
note()  { [ "$QUIET" = true ] || printf '%s  %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }
warn()  { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { printf '%s✗%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    [ -t 0 ] || die "$1 (re-run with --yes to confirm non-interactively)"
    local reply
    read -r -p "$1 [y/N] " reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

need_root() {
    [ "$(id -u)" -eq 0 ] || die "this command must run as root (try: sudo saucewg $*)"
}

# Uniformly distributed integer in [$1, $2] without depending on python.
rand_range() {
    local min=$1 max=$2 span raw
    span=$((max - min + 1))
    raw=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
    echo $((min + raw % span))
}

rand_secret() {
    # Base64 minus the characters that need quoting in .env or a URL.
    openssl rand -base64 "${1:-24}" | tr -d '/+=\n' | cut -c1-"${2:-24}"
}

# Secrets arrive on stdin rather than in argv, which is world-readable in /proc.
read_stdin_secret() {
    [ ! -t 0 ] || die "--psk-stdin expects the value on standard input"
    cat
}

public_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

# Rewrites KEY=value in a .env file, appending the key when it is not there yet.
env_set() {
    local file=$1 key=$2 value=$3
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # The value can contain slashes and ampersands, so build the line with awk.
        awk -v k="$key" -v v="$value" \
            'BEGIN { FS = "=" } $1 == k { print k "=" v; next } { print }' \
            "$file" > "${file}.tmp"
        mv "${file}.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
    chmod 600 "$file"
}

env_get() {
    local file=$1 key=$2
    [ -f "$file" ] || return 1
    sed -n "s/^${key}=//p" "$file" | tail -n1
}

image_ref() {
    local component=$1
    local base="${NAMESPACE}/${IMAGE_PREFIX}${component}:${IMAGE_TAG}"
    if [ "$REGISTRY" = "docker.io" ] || [ -z "$REGISTRY" ]; then
        printf '%s' "$base"
    else
        printf '%s/%s' "$REGISTRY" "$base"
    fi
}

# ---------------------------------------------------------------------------
# AmneziaWG generations
# ---------------------------------------------------------------------------
#
# A tunnel's generation is never negotiated: it is decided by which [Interface]
# obfuscation parameters the two ends carry, which is also how AmneziaVPN and
# KeeneticOS tell one profile from another.
#
#   1.0   Jc Jmin Jmax S1 S2 H1-H4          every KeeneticOS from 4.2 Alpha 2 on
#   1.5   the same, plus I1                 KeeneticOS 5.1 Alpha 3 and newer
#   2.0   the same, plus I1, S3 and S4      KeeneticOS 5.1 Alpha 3 and newer
#
# AWG 3.0 is deliberately absent: no router firmware speaks it, so a 3.0 profile
# cannot be loaded into a Keenetic at all.
#
# S1-S4 pad the four WireGuard message types and H1-H4 replace their type headers,
# so both ends must agree on them — which is why they travel in the exit node list.
# Jc/Jmin/Jmax (junk packets) and I1-I5 (signature packets) are built by the sender
# alone, so each end is free to use its own.
#
# This mirrors docker/awg/lib.sh and backend/app/awg/protocol.py; the three have to
# agree, and CI checks that they do.

AWG_PROTOCOLS="1.0 1.5 2.0"
AWG_PROTOCOL_LATEST="2.0"
AWG_OBF_PARAMS="JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5"

# Canonical name of a generation, or non-zero for anything unrecognised.
awg_protocol() {
    local value
    value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' _')
    case $value in
        ''|legacy|awg-legacy|awglegacy|1|1.0) printf '1.0' ;;
        1.5)                                  printf '1.5' ;;
        2|2.0)                                printf '2.0' ;;
        *) return 1 ;;
    esac
}

# The parameters that make up a profile of one generation, in .conf order. I2-I5 are
# opt-in extras rather than part of the identity, so they are absent here.
awg_protocol_params() {
    case "${1:-1.0}" in
        1.0) printf 'JC JMIN JMAX S1 S2 H1 H2 H3 H4' ;;
        1.5) printf 'JC JMIN JMAX S1 S2 H1 H2 H3 H4 I1' ;;
        2.0) printf 'JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 I1' ;;
    esac
}

awg_protocol_has() {
    local param=$2
    case $param in I[2-5]) param=I1 ;; esac
    case " $(awg_protocol_params "$1") " in *" $param "*) return 0 ;; esac
    return 1
}

require_protocol() {
    local resolved
    resolved=$(awg_protocol "${1:-}") \
        || die "AmneziaWG ${1} is not a generation SauceWG can serve (one of: ${AWG_PROTOCOLS})"
    printf '%s' "$resolved"
}

# A signature packet goes out ahead of the handshake so that the first thing a
# censor's classifier sees is a protocol it already passes. The far end never reads
# them, which is why the disguise can be chosen per node.
AWG_CPS_PRESETS="quic dns random short none"

awg_cps_preset() {
    case "${1:-}" in
        # A QUIC v1 long header: 0xc3, version 1, then 8-byte connection ids. UDP/443
        # is the usual entry port, so this matches what the traffic already looks like.
        quic)   printf '<b 0xc30000000108><r 8><b 0x08><r 8><b 0x0045dc><t><r 16>' ;;
        # A recursive A-record query for a random <6 chars>.com name.
        dns)    printf '<r 2><b 0x01000001000000000000><b 0x03><rc 3><b 0x06><rc 6><b 0x03636f6d00><b 0x00010001>' ;;
        random) printf '<r 128>' ;;
        # Some mobile carriers pass a short signature where a long one is dropped.
        short)  printf '<r 48>' ;;
        none)   printf '' ;;
        *) return 1 ;;
    esac
}

awg_cps_describe() {
    case "${1:-}" in
        quic)   printf 'a QUIC v1 long header on UDP/443' ;;
        dns)    printf 'a recursive DNS A-record query' ;;
        random) printf '128 random bytes' ;;
        short)  printf '48 random bytes, for carriers that drop long signatures' ;;
        none)   printf 'no signature packet' ;;
    esac
}

# Resolves a preset name to its spec and leaves a literal spec untouched, so the same
# option takes either.
awg_cps_spec() {
    local value=${1:-}
    case $value in
        '')   printf '' ;;
        *\<*) printf '%s' "$value" ;;
        *)    awg_cps_preset "$value" \
                  || die "unknown signature preset: ${value} (one of: ${AWG_CPS_PRESETS}, or a spec containing '<')" ;;
    esac
}

# Fills PROFILE_* with a complete obfuscation profile for one generation and clears
# the parameters that generation must not carry — so moving a node down from 2.0 to
# 1.0 really does stop it advertising S3, S4 and I1. Values already set are kept,
# which is how an operator pins one parameter and has the rest generated. The third
# argument says whether app clients or another node dial this interface; it has to
# match what docker/awg/lib.sh does for the same interface.
generate_profile() {
    local protocol=$1 signature=${2:-} peers=${3:-clients} suffix name
    case $peers in
        clients|nodes) ;;
        *) die "generate_profile: peers must be 'clients' or 'nodes', got: ${peers}" ;;
    esac
    for suffix in $AWG_OBF_PARAMS; do
        name="PROFILE_${suffix}"
        awg_protocol_has "$protocol" "$suffix" || printf -v "$name" '%s' ''
    done

    [ -n "${PROFILE_JC:-}" ]   || PROFILE_JC=$(rand_range 3 10)
    [ -n "${PROFILE_JMIN:-}" ] || PROFILE_JMIN=50
    [ -n "${PROFILE_JMAX:-}" ] || PROFILE_JMAX=1000
    [ -n "${PROFILE_S1:-}" ]   || PROFILE_S1=$(rand_range 15 150)
    if [ -z "${PROFILE_S2:-}" ]; then
        while :; do
            PROFILE_S2=$(rand_range 15 150)
            # AmneziaWG requires S1 + 56 != S2 so the init and response packets do
            # not end up the same length.
            [ "$((PROFILE_S1 + 56))" -ne "$PROFILE_S2" ] && break
        done
    fi

    if awg_protocol_has "$protocol" S3; then
        # S3 and S4 pad the cookie reply and every transport packet, and both ends have
        # to agree on them. The AmneziaVPN app drops them while importing a profile, so
        # an interface app clients dial pads by zero — otherwise the handshake still
        # completes and every transport packet the app sends is discarded as malformed.
        # A node-to-node hop runs amneziawg-go at both ends, which honours them.
        if [ "$peers" = clients ]; then
            [ -n "${PROFILE_S3:-}" ] || PROFILE_S3=0
            [ -n "${PROFILE_S4:-}" ] || PROFILE_S4=0
        else
            [ -n "${PROFILE_S3:-}" ] || PROFILE_S3=$(rand_range 8 55)
            [ -n "${PROFILE_S4:-}" ] || PROFILE_S4=$(rand_range 4 27)
        fi
    fi

    local seen="" value
    # shellcheck disable=SC2153  # PROFILE_H1-H4 are assigned through $name below
    for suffix in H1 H2 H3 H4; do
        name="PROFILE_${suffix}"
        value=${!name:-}
        if [ -z "$value" ]; then
            while :; do
                # amneziawg-windows-client rejects anything above INT32_MAX.
                value=$(rand_range 5 2147483647)
                case " $seen " in *" $value "*) continue ;; esac
                break
            done
            printf -v "$name" '%s' "$value"
        fi
        seen="$seen $value"
    done

    if awg_protocol_has "$protocol" I1; then
        [ -n "$signature" ] || signature=${PROFILE_I1:-quic}
        PROFILE_I1=$(awg_cps_spec "$signature")
    fi
}

# Writes the profile into a .env, clearing the parameters the generation dropped so
# the node container is not handed a leftover from the generation before.
store_profile() {
    local file=$1 protocol=$2 suffix name
    env_set "$file" AWG_PROTOCOL "$protocol"
    for suffix in $AWG_OBF_PARAMS; do
        name="PROFILE_${suffix}"
        env_set "$file" "AWG_${suffix}" "${!name:-}"
    done
}

# Loads whatever profile a .env already carries into PROFILE_*, so a generation
# change keeps the parameters both generations share and only fills the new ones.
load_profile() {
    local file=$1 suffix
    for suffix in $AWG_OBF_PARAMS; do
        printf -v "PROFILE_${suffix}" '%s' "$(env_get "$file" "AWG_${suffix}" || true)"
    done
}

clear_profile() {
    local suffix
    for suffix in $AWG_OBF_PARAMS; do
        printf -v "PROFILE_${suffix}" '%s' ''
    done
}

# ---------------------------------------------------------------------------
# Host preparation
# ---------------------------------------------------------------------------

pkg_manager() {
    for candidate in apt-get dnf yum zypper pacman apk; do
        command -v "$candidate" >/dev/null 2>&1 && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

install_packages() {
    local manager
    manager=$(pkg_manager) || { warn "no supported package manager found; install $* by hand"; return 0; }
    log "installing $* with ${manager}"
    case "$manager" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >&2
            ;;
        dnf)    dnf install -y -q "$@" >&2 ;;
        yum)    yum install -y -q "$@" >&2 ;;
        zypper) zypper --non-interactive install -y "$@" >&2 ;;
        pacman) pacman -Sy --noconfirm "$@" >&2 ;;
        apk)    apk add --no-cache "$@" >&2 ;;
    esac
}

ensure_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    [ "${#missing[@]}" -eq 0 ] || install_packages "${missing[@]}"

    for binary in curl jq openssl; do
        command -v "$binary" >/dev/null 2>&1 || die "${binary} is required but could not be installed"
    done
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "installing Docker from get.docker.com"
        curl -fsSL https://get.docker.com | sh >&2 \
            || die "Docker installation failed; install it manually and re-run"
    fi
    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose v2 is missing. Update Docker or install the compose plugin."
    fi
    if ! docker info >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
    fi
}

ensure_forwarding() {
    cat > /etc/sysctl.d/99-saucewg.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
    sysctl -q -p /etc/sysctl.d/99-saucewg.conf >/dev/null 2>&1 || true
    # /dev/net/tun is missing on some minimal and container-in-container hosts.
    # Not being able to create it is not fatal here: docker reports it clearly when
    # the node container starts, and the rest of the install is still worth doing.
    if [ ! -c /dev/net/tun ]; then
        if mkdir -p /dev/net 2>/dev/null && mknod /dev/net/tun c 10 200 2>/dev/null; then
            chmod 600 /dev/net/tun 2>/dev/null || true
        else
            warn "/dev/net/tun is missing and could not be created; the node will not start until it exists"
        fi
    fi
}

# Puts a copy of this script on PATH so the server can be managed with `saucewg`.
install_cli() {
    # A missing `saucewg` command is an inconvenience, not a broken install, so
    # every failure here is a warning: the deployment itself is still fine.
    local source="${BASH_SOURCE[0]}"
    mkdir -p "$(dirname "$CLI_PATH")" 2>/dev/null || true
    if [ -f "$source" ] && [ -r "$source" ]; then
        # A remote installer is uploaded straight to CLI_PATH and run from there,
        # so this may already be the destination.
        if [ "$(readlink -f "$source" 2>/dev/null)" = "$(readlink -f "$CLI_PATH" 2>/dev/null)" ]; then
            chmod 0755 "$CLI_PATH" 2>/dev/null || true
            log "the saucewg command is already at ${CLI_PATH}"
            return 0
        fi
        cp "$source" "$CLI_PATH" 2>/dev/null || {
            warn "could not install the saucewg command at ${CLI_PATH}"
            return 0
        }
    else
        # Running from a pipe (curl | bash): fetch a copy instead of reading stdin.
        curl -fsSL "${RAW_BASE}/saucewg.sh" -o "$CLI_PATH" 2>/dev/null || {
            warn "could not download saucewg.sh from ${RAW_BASE} to ${CLI_PATH}"
            return 0
        }
    fi
    chmod 0755 "$CLI_PATH" 2>/dev/null || true
    log "installed the saucewg command at ${CLI_PATH}"
}

# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------

compose() {
    docker compose --project-directory "$APP_DIR" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

role() {
    [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || printf 'unknown'
}

require_installed() {
    [ -f "$COMPOSE_FILE" ] && [ -f "$ENV_FILE" ] \
        || die "SauceWG is not installed in ${APP_DIR}. Run: saucewg install (or install-node)"
}

write_entry_compose() {
    cat > "$COMPOSE_FILE" <<'YAML'
# Generated by saucewg.sh — edit .env instead of this file.
name: ${COMPOSE_PROJECT_NAME:-saucewg}

x-restart: &restart
  restart: unless-stopped

services:
  postgres:
    <<: *restart
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-saucewg}
      POSTGRES_USER: ${POSTGRES_USER:-saucewg}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-saucewg} -d ${POSTGRES_DB:-saucewg}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [internal]

  awg:
    <<: *restart
    image: ${IMAGE_AWG}
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      AWG_ROLE: entry
      AWG_IFACE: ${AWG_IFACE:-awg0}
      AWG_PORT: ${AWG_PORT:-51820}
      AWG_SUBNET: ${AWG_SUBNET:-10.8.0.0/24}
      AWG_MTU: ${AWG_MTU:-1420}
      AWG_PRIVATE_KEY: ${AWG_PRIVATE_KEY:-}
      AWG_PROTOCOL: ${AWG_PROTOCOL:-}
      AWG_JC: ${AWG_JC:-}
      AWG_JMIN: ${AWG_JMIN:-}
      AWG_JMAX: ${AWG_JMAX:-}
      AWG_S1: ${AWG_S1:-}
      AWG_S2: ${AWG_S2:-}
      AWG_S3: ${AWG_S3:-}
      AWG_S4: ${AWG_S4:-}
      AWG_H1: ${AWG_H1:-}
      AWG_H2: ${AWG_H2:-}
      AWG_H3: ${AWG_H3:-}
      AWG_H4: ${AWG_H4:-}
      AWG_I1: ${AWG_I1:-}
      AWG_I2: ${AWG_I2:-}
      AWG_I3: ${AWG_I3:-}
      AWG_I4: ${AWG_I4:-}
      AWG_I5: ${AWG_I5:-}
      CASCADE_ENABLED: ${CASCADE_ENABLED:-true}
      CASCADE_PROTOCOL_DEFAULT: ${CASCADE_PROTOCOL_DEFAULT:-}
      CASCADE_MTU: ${CASCADE_MTU:-1380}
      CASCADE_KEEPALIVE: ${CASCADE_KEEPALIVE:-25}
      CASCADE_KILLSWITCH: ${CASCADE_KILLSWITCH:-true}
      CASCADE_NODES_JSON: ${CASCADE_NODES_JSON:-}
      CASCADE_NODES_FILE: ${CASCADE_NODES_FILE:-/etc/amnezia/host/exit-nodes.json}
      CASCADE_UPLINK_SUBNET: ${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}
      CASCADE_PROBE_ENABLED: ${CASCADE_PROBE_ENABLED:-true}
      CASCADE_PROBE_TARGET: ${CASCADE_PROBE_TARGET:-1.1.1.1}
      CASCADE_PROBE_INTERVAL: ${CASCADE_PROBE_INTERVAL:-10}
      CASCADE_PROBE_TIMEOUT: ${CASCADE_PROBE_TIMEOUT:-3}
      CASCADE_FAIL_THRESHOLD: ${CASCADE_FAIL_THRESHOLD:-3}
      CASCADE_RECOVER_THRESHOLD: ${CASCADE_RECOVER_THRESHOLD:-2}
      CASCADE_HANDSHAKE_TIMEOUT: ${CASCADE_HANDSHAKE_TIMEOUT:-180}
    volumes:
      - awg-config:/etc/amnezia/amneziawg
      - awg-run:/var/run/amneziawg
      - ./config:/etc/amnezia/host:ro

  panel:
    <<: *restart
    image: ${IMAGE_PANEL}
    depends_on:
      postgres:
        condition: service_healthy
      awg:
        condition: service_started
    environment:
      PANEL_TITLE: ${PANEL_TITLE:-SauceWG}
      DEBUG: ${DEBUG:-false}
      DOCS_ENABLED: ${DOCS_ENABLED:-true}
      LOG_LEVEL: ${LOG_LEVEL:-info}
      CORS_ORIGINS: ${CORS_ORIGINS:-*}
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB:-saucewg}
      POSTGRES_USER: ${POSTGRES_USER:-saucewg}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET must be set}
      JWT_ACCESS_TOKEN_EXPIRE_MINUTES: ${JWT_ACCESS_TOKEN_EXPIRE_MINUTES:-1440}
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}
      AWG_IFACE: ${AWG_IFACE:-awg0}
      AWG_SUBNET: ${AWG_SUBNET:-10.8.0.0/24}
      AWG_ENDPOINT_HOST: ${AWG_ENDPOINT_HOST:?AWG_ENDPOINT_HOST must be set}
      AWG_ENDPOINT_PORT: ${AWG_PORT:-51820}
      CASCADE_ENABLED: ${CASCADE_ENABLED:-true}
      CASCADE_UPLINK_SUBNET: ${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}
      CLIENT_DNS: ${CLIENT_DNS:-1.1.1.1, 1.0.0.1}
      CLIENT_MTU: ${CLIENT_MTU:-1280}
      CLIENT_ALLOWED_IPS: ${CLIENT_ALLOWED_IPS:-0.0.0.0/0, ::/0}
      CLIENT_KEEPALIVE: ${CLIENT_KEEPALIVE:-25}
      CLIENT_JC: ${CLIENT_JC:-0}
      CLIENT_JMIN: ${CLIENT_JMIN:-0}
      CLIENT_JMAX: ${CLIENT_JMAX:-0}
      CLIENT_SIGNATURE: ${CLIENT_SIGNATURE:-}
      COLLECTOR_INTERVAL_SECONDS: ${COLLECTOR_INTERVAL_SECONDS:-10}
      SYNC_INTERVAL_SECONDS: ${SYNC_INTERVAL_SECONDS:-30}
      ONLINE_TIMEOUT_SECONDS: ${ONLINE_TIMEOUT_SECONDS:-180}
      USAGE_BUCKET_MINUTES: ${USAGE_BUCKET_MINUTES:-60}
      USAGE_RETENTION_DAYS: ${USAGE_RETENTION_DAYS:-90}
      SUBSCRIPTION_URL_PREFIX: ${SUBSCRIPTION_URL_PREFIX:-}
      NODE_REGISTRY_FILE: ${NODE_REGISTRY_FILE:-/etc/saucewg/host/exit-nodes.json}
      NODE_PROVISION_ENABLED: ${NODE_PROVISION_ENABLED:-true}
      NODE_DEFAULT_PORT: ${NODE_DEFAULT_PORT:-51820}
      NODE_SSH_TIMEOUT_SECONDS: ${NODE_SSH_TIMEOUT_SECONDS:-900}
      NODE_SSH_QUERY_TIMEOUT_SECONDS: ${NODE_SSH_QUERY_TIMEOUT_SECONDS:-60}
      NODE_SSH_KEY_FILE: ${NODE_SSH_KEY_FILE:-/etc/saucewg/host/panel-ssh-key}
      NODE_SSH_KEY_ENABLED: ${NODE_SSH_KEY_ENABLED:-true}
      SAUCEWG_REPO: ${SAUCEWG_REPO:-V2as/SauceWG}
      SAUCEWG_REF: ${SAUCEWG_REF:-main}
      SAUCEWG_NAMESPACE: ${SAUCEWG_NAMESPACE:-v2as}
      SAUCEWG_IMAGE_PREFIX: ${SAUCEWG_IMAGE_PREFIX:-saucewg-}
      SAUCEWG_TAG: ${SAUCEWG_TAG:-latest}
    volumes:
      - awg-config:/etc/amnezia/amneziawg:ro
      - awg-run:/var/run/amneziawg
      - ./config:/etc/saucewg/host
    networks: [internal]

  caddy:
    <<: *restart
    image: ${IMAGE_WEB}
    depends_on: [panel]
    environment:
      PANEL_SITE_ADDRESS: ${PANEL_SITE_ADDRESS:-:80}
      CADDY_AUTO_HTTPS: ${CADDY_AUTO_HTTPS:-off}
    ports:
      - "${PANEL_HTTP_PORT:-80}:80"
      - "${PANEL_HTTPS_PORT:-443}:443"
    volumes:
      - caddy-data:/data
      - caddy-config:/config
    networks: [internal]

networks:
  internal:
    driver: bridge

volumes:
  pgdata:
  awg-config:
  awg-run:
  caddy-data:
  caddy-config:
YAML
}

write_exit_compose() {
    cat > "$COMPOSE_FILE" <<'YAML'
# Generated by saucewg.sh — edit .env instead of this file.
name: ${COMPOSE_PROJECT_NAME:-saucewg-exit}

services:
  awg:
    image: ${IMAGE_AWG}
    restart: unless-stopped
    network_mode: host
    cap_add: [NET_ADMIN, NET_RAW]
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      AWG_ROLE: exit
      AWG_IFACE: ${AWG_IFACE:-awg0}
      AWG_PORT: ${AWG_PORT:-51820}
      AWG_SUBNET: ${AWG_SUBNET:-10.77.0.0/24}
      AWG_MTU: ${AWG_MTU:-1420}
      AWG_PRIVATE_KEY: ${AWG_PRIVATE_KEY:-}
      AWG_PROTOCOL: ${AWG_PROTOCOL:-}
      AWG_JC: ${AWG_JC:-}
      AWG_JMIN: ${AWG_JMIN:-}
      AWG_JMAX: ${AWG_JMAX:-}
      AWG_S1: ${AWG_S1:-}
      AWG_S2: ${AWG_S2:-}
      AWG_S3: ${AWG_S3:-}
      AWG_S4: ${AWG_S4:-}
      AWG_H1: ${AWG_H1:-}
      AWG_H2: ${AWG_H2:-}
      AWG_H3: ${AWG_H3:-}
      AWG_H4: ${AWG_H4:-}
      AWG_I1: ${AWG_I1:-}
      AWG_I2: ${AWG_I2:-}
      AWG_I3: ${AWG_I3:-}
      AWG_I4: ${AWG_I4:-}
      AWG_I5: ${AWG_I5:-}
      AWG_PEER_PUBLIC_KEY: ${AWG_PEER_PUBLIC_KEY:-}
      AWG_PEER_PSK: ${AWG_PEER_PSK:-}
      AWG_PEER_ALLOWED_IPS: ${AWG_PEER_ALLOWED_IPS:-10.77.0.0/24}
      WAN_IFACE: ${WAN_IFACE:-}
    volumes:
      - awg-config:/etc/amnezia/amneziawg
      - awg-run:/var/run/amneziawg

volumes:
  awg-config:
  awg-run:
YAML
}

# ---------------------------------------------------------------------------
# install — the entry node (panel + cascade)
# ---------------------------------------------------------------------------

cmd_install() {
    need_root install

    local domain="" http_port="" https_port="" admin_user="admin" admin_password=""
    local awg_port=443 subnet=10.8.0.0/24 uplink_subnet=10.77.0.0/24 endpoint_host=""
    local start=true reinstall=false protocol="" signature=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --domain) domain=$2; shift 2 ;;
            --http-port|--panel-port) http_port=$2; shift 2 ;;
            --https-port) https_port=$2; shift 2 ;;
            --admin-username) admin_user=$2; shift 2 ;;
            --admin-password) admin_password=$2; shift 2 ;;
            --port) awg_port=$2; shift 2 ;;
            --subnet) subnet=$2; shift 2 ;;
            --uplink-subnet) uplink_subnet=$2; shift 2 ;;
            --endpoint-host|--host) endpoint_host=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --signature|--cps) signature=$2; shift 2 ;;
            --no-start) start=false; shift ;;
            --reinstall) reinstall=true; shift ;;
            *) die "unknown option for install: $1" ;;
        esac
    done

    # A fresh install has no clients to keep working, so it starts on the newest
    # generation KeeneticOS accepts rather than on 1.0.
    protocol=$(require_protocol "${protocol:-$AWG_PROTOCOL_LATEST}")

    if [ -f "$ENV_FILE" ] && [ "$reinstall" = false ]; then
        die "${APP_DIR} already holds an installation. Use 'saucewg update', or pass --reinstall."
    fi

    [ -n "$http_port" ] || http_port=80
    [ -n "$https_port" ] || https_port=443

    step "Preparing the host"
    ensure_deps
    ensure_docker
    ensure_forwarding

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$APP_DIR"
    printf 'entry\n' > "$ROLE_FILE"

    if [ ! -f "$NODES_FILE" ]; then
        printf '[]\n' > "$NODES_FILE"
        chmod 600 "$NODES_FILE"
    fi

    step "Writing the configuration"
    if [ -z "$endpoint_host" ]; then
        endpoint_host=$(public_ip) || die "could not detect the public IP; pass --endpoint-host"
        note "detected public address ${endpoint_host}"
    fi
    [ -n "$admin_password" ] || admin_password=$(rand_secret 18 20)

    clear_profile
    generate_profile "$protocol" "$signature" clients

    local site_address="${http_port}" auto_https=off
    if [ -n "$domain" ]; then
        site_address="$domain"
        auto_https=on
    else
        site_address=":80"
    fi

    cat > "$ENV_FILE" <<EOF
# Generated by saucewg.sh v${SAUCEWG_VERSION} — $(date -u +%Y-%m-%dT%H:%M:%SZ)
COMPOSE_PROJECT_NAME=saucewg

IMAGE_AWG=$(image_ref awg)
IMAGE_PANEL=$(image_ref panel)
IMAGE_WEB=$(image_ref web)

SAUCEWG_REPO=${SAUCEWG_REPO}
SAUCEWG_REF=${SAUCEWG_REF}
SAUCEWG_NAMESPACE=${NAMESPACE}
SAUCEWG_IMAGE_PREFIX=${IMAGE_PREFIX}
SAUCEWG_TAG=${IMAGE_TAG}

PANEL_TITLE=SauceWG
PANEL_HTTP_PORT=${http_port}
PANEL_HTTPS_PORT=${https_port}
PANEL_SITE_ADDRESS=${site_address}
CADDY_AUTO_HTTPS=${auto_https}
DOCS_ENABLED=true
LOG_LEVEL=info
DEBUG=false
CORS_ORIGINS=*

ADMIN_USERNAME=${admin_user}
ADMIN_PASSWORD=${admin_password}
JWT_SECRET=$(openssl rand -hex 32)
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=1440

POSTGRES_DB=saucewg
POSTGRES_USER=saucewg
POSTGRES_PASSWORD=$(openssl rand -hex 24)

AWG_IFACE=awg0
AWG_PORT=${awg_port}
AWG_SUBNET=${subnet}
AWG_MTU=1420
AWG_ENDPOINT_HOST=${endpoint_host}
AWG_PRIVATE_KEY=
AWG_PROTOCOL=${protocol}
AWG_JC=${PROFILE_JC}
AWG_JMIN=${PROFILE_JMIN}
AWG_JMAX=${PROFILE_JMAX}
AWG_S1=${PROFILE_S1}
AWG_S2=${PROFILE_S2}
AWG_S3=${PROFILE_S3}
AWG_S4=${PROFILE_S4}
AWG_H1=${PROFILE_H1}
AWG_H2=${PROFILE_H2}
AWG_H3=${PROFILE_H3}
AWG_H4=${PROFILE_H4}
AWG_I1=${PROFILE_I1}
AWG_I2=
AWG_I3=
AWG_I4=
AWG_I5=

CASCADE_ENABLED=true
CASCADE_PROTOCOL_DEFAULT=${protocol}
CASCADE_MTU=1380
CASCADE_KEEPALIVE=25
CASCADE_KILLSWITCH=true
CASCADE_NODES_FILE=/etc/amnezia/host/exit-nodes.json
CASCADE_UPLINK_SUBNET=${uplink_subnet}
CASCADE_PROBE_ENABLED=true
CASCADE_PROBE_TARGET=1.1.1.1
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
CLIENT_SIGNATURE=

COLLECTOR_INTERVAL_SECONDS=10
SYNC_INTERVAL_SECONDS=30
ONLINE_TIMEOUT_SECONDS=180
USAGE_BUCKET_MINUTES=60
USAGE_RETENTION_DAYS=90
SUBSCRIPTION_URL_PREFIX=

NODE_REGISTRY_FILE=/etc/saucewg/host/exit-nodes.json
NODE_PROVISION_ENABLED=true
NODE_DEFAULT_PORT=51820
NODE_SSH_TIMEOUT_SECONDS=900
NODE_SSH_KEY_FILE=/etc/saucewg/host/panel-ssh-key
NODE_SSH_KEY_ENABLED=true
EOF
    chmod 600 "$ENV_FILE"

    write_entry_compose
    install_cli

    local healthy=true
    if [ "$start" = true ]; then
        step "Pulling images"
        compose pull --quiet >&2 || die "could not pull the images from ${REGISTRY}/${NAMESPACE}"
        step "Starting SauceWG"
        compose up -d >&2
        wait_for_panel
        wait_for_containers || healthy=false
    fi

    local scheme=http url
    [ "$auto_https" = on ] && scheme=https
    if [ -n "$domain" ]; then
        url="${scheme}://${domain}"
    else
        url="http://${endpoint_host}"
        [ "$http_port" = "80" ] || url="${url}:${http_port}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg role entry --arg dir "$APP_DIR" --arg url "$url" \
              --arg username "$admin_user" --arg password "$admin_password" \
              --arg endpoint "${endpoint_host}:${awg_port}" --arg version "$SAUCEWG_VERSION" \
              --arg protocol "$protocol" --argjson healthy "$healthy" \
              '{ok: $healthy, role: $role, dir: $dir, panel_url: $url, admin_username: $username,
                admin_password: $password, endpoint: $endpoint, version: $version,
                protocol: $protocol}'
    fi

    step "SauceWG is installed"
    note "panel     ${url}"
    note "username  ${admin_user}"
    note "password  ${admin_password}"
    note "endpoint  ${endpoint_host}:${awg_port}/udp"
    note "protocol  AmneziaWG ${protocol}"
    note ""
    note "Add exit nodes from the panel's Exit nodes page, or with:"
    note "  saucewg add-node --json '<object from: saucewg install-node --json>'"
    if [ "$healthy" = false ]; then
        warn ""
        warn "Some containers are not running, so ${url} will not answer yet."
        warn "The credentials above are already written to ${ENV_FILE} and stay valid."
        warn "See what happened with: saucewg logs"
    fi
    [ -n "$domain" ] || warn "The panel is served over plain HTTP. Re-run with --domain to enable TLS."
    if [ "$protocol" != "1.0" ]; then
        note ""
        note "AmneziaWG ${protocol} needs KeeneticOS 5.1 Alpha 3 or newer on a router, and a"
        note "recent AmneziaVPN on phones and desktops. For an older Keenetic, either"
        note "install with --protocol 1.0 or move this node later with:"
        note "  saucewg set-protocol 1.0"
    fi
}

wait_for_panel() {
    local tries=0
    log "waiting for the panel to answer"
    while [ "$tries" -lt 60 ]; do
        if compose exec -T panel curl -fsS http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
            log "the panel is up"
            return 0
        fi
        tries=$((tries + 1))
        sleep 2
    done
    warn "the panel did not answer within two minutes; check: saucewg logs panel"
    return 0
}

# `compose up -d` returns once the containers are created, and the restart policy
# then hides one that exits on startup: an unreadable config or a bad image reads
# as a finished install right up until someone opens the URL. So the states are
# read back, and a container still not running is named.
wait_for_containers() {
    local tries=0 broken=""
    log "checking that every container stays up"
    while [ "$tries" -lt 20 ]; do
        broken=$(compose ps --format json 2>/dev/null | jq -rs '
            map(select((.State // "") != "running"))
            | map("\(.Service // .Name) (\(.State // "unknown"))") | join(", ")' 2>/dev/null) \
            || broken=""
        if [ -z "$broken" ]; then
            log "every container is running"
            return 0
        fi
        tries=$((tries + 1))
        sleep 3
    done
    warn "not running a minute after startup: ${broken}"
    for service in $(compose ps --services 2>/dev/null); do
        compose ps --format json 2>/dev/null \
            | jq -rs --arg s "$service" 'map(select((.Service // .Name) == $s
                and (.State // "") != "running")) | length' 2>/dev/null | grep -qx 1 || continue
        warn "  last words from ${service}:"
        compose logs --tail 3 --no-log-prefix "$service" 2>&1 | sed 's/^/      /' >&2
    done
    return 1
}

# ---------------------------------------------------------------------------
# install-node — an exit node
# ---------------------------------------------------------------------------

cmd_install_node() {
    need_root install-node

    local name="" port=51820 subnet=10.77.0.0/24 peer_allowed=10.77.0.0/24
    local peer_key="" psk="" endpoint_host="" reinstall=false start=true
    local protocol="" signature="" requested_protocol=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name=$2; shift 2 ;;
            --port) port=$2; shift 2 ;;
            --subnet) subnet=$2; shift 2 ;;
            --peer-allowed-ips) peer_allowed=$2; shift 2 ;;
            --peer-key) peer_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --psk-stdin) psk=$(read_stdin_secret); shift ;;
            --endpoint-host|--host) endpoint_host=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; requested_protocol=true; shift 2 ;;
            --signature|--cps) signature=$2; requested_protocol=true; shift 2 ;;
            --no-start) start=false; shift ;;
            --reinstall) reinstall=true; shift ;;
            *) die "unknown option for install-node: $1" ;;
        esac
    done

    [ -n "$name" ] || name=$(hostname -s 2>/dev/null || echo exit)
    protocol=$(require_protocol "${protocol:-$AWG_PROTOCOL_LATEST}")

    if [ -f "$ENV_FILE" ] && [ "$reinstall" = false ]; then
        [ "$(role)" = "exit" ] || die "${APP_DIR} already holds a $(role) installation"
        log "reusing the existing exit node installation in ${APP_DIR}"
        # Re-running the installer against a node that is already up must not move it
        # to another generation behind the operator's back: the entry node is paired
        # with the profile it has now.
        if [ "$requested_protocol" = true ]; then
            load_profile "$ENV_FILE"
            generate_profile "$protocol" "$signature" nodes
            store_profile "$ENV_FILE" "$protocol"
            log "moved this node to AmneziaWG ${protocol}"
        fi
    else
        step "Preparing the host"
        ensure_deps
        ensure_docker
        ensure_forwarding

        mkdir -p "$APP_DIR"
        chmod 700 "$APP_DIR"
        printf 'exit\n' > "$ROLE_FILE"

        step "Writing the configuration"
        clear_profile
        generate_profile "$protocol" "$signature" nodes

        cat > "$ENV_FILE" <<EOF
# Generated by saucewg.sh v${SAUCEWG_VERSION} — $(date -u +%Y-%m-%dT%H:%M:%SZ)
COMPOSE_PROJECT_NAME=saucewg-exit

IMAGE_AWG=$(image_ref awg)

SAUCEWG_NODE_NAME=${name}
SAUCEWG_TAG=${IMAGE_TAG}

AWG_IFACE=awg0
AWG_PORT=${port}
AWG_SUBNET=${subnet}
AWG_MTU=1420
AWG_PRIVATE_KEY=

AWG_PROTOCOL=${protocol}
AWG_JC=${PROFILE_JC}
AWG_JMIN=${PROFILE_JMIN}
AWG_JMAX=${PROFILE_JMAX}
AWG_S1=${PROFILE_S1}
AWG_S2=${PROFILE_S2}
AWG_S3=${PROFILE_S3}
AWG_S4=${PROFILE_S4}
AWG_H1=${PROFILE_H1}
AWG_H2=${PROFILE_H2}
AWG_H3=${PROFILE_H3}
AWG_H4=${PROFILE_H4}
AWG_I1=${PROFILE_I1}
AWG_I2=
AWG_I3=
AWG_I4=
AWG_I5=

AWG_PEER_PUBLIC_KEY=${peer_key}
AWG_PEER_PSK=${psk}
AWG_PEER_ALLOWED_IPS=${peer_allowed}
WAN_IFACE=
EOF
        chmod 600 "$ENV_FILE"
        write_exit_compose
        install_cli
    fi

    [ -z "$peer_key" ] || env_set "$ENV_FILE" AWG_PEER_PUBLIC_KEY "$peer_key"
    [ -z "$psk" ] || env_set "$ENV_FILE" AWG_PEER_PSK "$psk"
    [ -z "$endpoint_host" ] || env_set "$ENV_FILE" SAUCEWG_ENDPOINT_HOST "$endpoint_host"

    open_node_port "$port"

    if [ "$start" = false ]; then
        step "Exit node is configured"
        note "start it with: saucewg start"
        [ "$JSON_OUTPUT" = false ] || jq -n --arg dir "$APP_DIR" --arg name "$name" \
            '{ok: true, role: "exit", dir: $dir, name: $name, started: false}'
        return 0
    fi

    step "Pulling images"
    compose pull --quiet >&2 || die "could not pull ${IMAGE_TAG} from ${REGISTRY}/${NAMESPACE}"
    step "Starting the exit node"
    compose up -d >&2

    wait_for_params

    step "Exit node is ready"
    emit_node_info
}

# The node is only dialled by the entry node, but a default-deny firewall would
# still swallow the handshake, so punch the port through the common ones.
open_node_port() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw allow "${port}/udp" >/dev/null 2>&1 && log "opened ${port}/udp in ufw" || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 && log "opened ${port}/udp in firewalld" || true
    fi
}

wait_for_params() {
    local iface tries=0
    iface=$(env_get "$ENV_FILE" AWG_IFACE || echo awg0)
    while [ "$tries" -lt 45 ]; do
        if compose exec -T awg test -f "/etc/amnezia/amneziawg/${iface}.params" >/dev/null 2>&1; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 2
    done
    die "the node container did not come up; check: saucewg logs awg"
}

# Prints the object that goes straight into the entry node's exit-node list.
emit_node_info() {
    require_installed
    [ "$(role)" = "exit" ] || die "node-info only applies to an exit node"

    local iface params host port name
    iface=$(env_get "$ENV_FILE" AWG_IFACE || echo awg0)
    params=$(compose exec -T awg cat "/etc/amnezia/amneziawg/${iface}.params" 2>/dev/null) \
        || die "could not read the node parameters; is the node running?"

    name=$(env_get "$ENV_FILE" SAUCEWG_NODE_NAME || true)
    [ -n "$name" ] || name=$(hostname -s 2>/dev/null || echo exit)
    host=$(env_get "$ENV_FILE" SAUCEWG_ENDPOINT_HOST || true)
    [ -n "$host" ] || host=$(public_ip) || die "could not detect the public IP; pass --endpoint-host"
    port=$(printf '%s' "$params" | sed -n 's/^SERVER_PORT=//p')

    # Only the parameters the node's generation actually carries are reported: an
    # extra S3 in the list would have the entry node build a 2.0 uplink towards an
    # exit node that speaks 1.0, and the handshake would never complete.
    local json
    json=$(printf '%s' "$params" | jq -R -s \
        --arg name "$name" --arg host "$host" --arg port "$port" \
        --arg shared "S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5" '
        def unquote:
            if startswith("\u0027") and endswith("\u0027")
            then .[1:-1] | gsub("\u0027\\\\\u0027\u0027"; "\u0027")
            else . end;
        def numeric: if test("^[0-9]+$") then tonumber else . end;
        split("\n")
        | map(select(length > 0) | split("=") | {key: .[0], value: (.[1:] | join("=") | unquote)})
        | from_entries
        | . as $p
        | {
            name: $name,
            endpoint: "\($host):\($port)",
            public_key: $p.SERVER_PUBLIC_KEY,
            port: ($port | tonumber),
            protocol: ($p.SERVER_PROTOCOL // "1.0")
          }
        + (reduce ($shared | split(" "))[] as $k ({};
              ($p["SERVER_" + $k]) as $v
              | if ($v // "") == "" then . else . + {($k | ascii_downcase): ($v | numeric)} end))')

    if [ "$JSON_OUTPUT" = true ]; then
        printf '%s\n' "$json"
    else
        note "Add this object to the entry node:"
        printf '%s\n' "$json"
        note ""
        note "  saucewg add-node --json '<the object above>'   # on the entry node"
    fi
}

cmd_node_info() {
    while [ $# -gt 0 ]; do
        case "$1" in
            *) die "unknown option for node-info: $1" ;;
        esac
    done
    emit_node_info
}

# Installs the entry node's uplink public key so the tunnel can come up.
cmd_node_pair() {
    need_root node-pair
    require_installed
    [ "$(role)" = "exit" ] || die "node-pair only applies to an exit node"

    local peer_key="" psk="" clear_psk=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --peer-key|--key) peer_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --psk-stdin) psk=$(read_stdin_secret); shift ;;
            --no-psk) clear_psk=true; shift ;;
            *) die "unknown option for node-pair: $1" ;;
        esac
    done
    [ -n "$peer_key" ] || die "--peer-key is required"

    env_set "$ENV_FILE" AWG_PEER_PUBLIC_KEY "$peer_key"
    [ -z "$psk" ] || env_set "$ENV_FILE" AWG_PEER_PSK "$psk"
    [ "$clear_psk" = false ] || env_set "$ENV_FILE" AWG_PEER_PSK ""

    log "pairing with the entry node and restarting"
    compose up -d --force-recreate awg >&2
    wait_for_params

    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg key "$peer_key" '{ok: true, paired: true, peer_public_key: $key}'
    else
        log "paired with ${peer_key}"
    fi
}

# ---------------------------------------------------------------------------
# Exit node list management (entry node)
# ---------------------------------------------------------------------------

require_entry() {
    require_installed
    [ "$(role)" = "entry" ] || die "this command only applies to the entry node"
}

nodes_file() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$NODES_FILE" ] || { printf '[]\n' > "$NODES_FILE"; chmod 600 "$NODES_FILE"; }
    printf '%s' "$NODES_FILE"
}

# Asks the node container to re-read the list. It picks the request up within a
# second, so no container restart and no interruption for connected clients.
request_reload() {
    local id
    # A nanosecond epoch does not survive a round trip through a JSON number, so
    # the id travels as a string on both sides.
    id=$(date -u +%s%N)
    compose exec -T awg sh -c "printf '{\"id\":\"%s\"}' '$id' > /var/run/amneziawg/reload.request" >/dev/null 2>&1 \
        || { warn "could not reach the node container; restarting it instead"; compose up -d --force-recreate awg >&2; sleep 5; return 0; }

    local tries=0 applied
    while [ "$tries" -lt 60 ]; do
        applied=$(compose exec -T awg jq -r '.reload_id // 0' /var/run/amneziawg/uplinks.json 2>/dev/null) || applied=0
        [ "$applied" = "$id" ] && { log "the node applied the new list"; return 0; }
        tries=$((tries + 1))
        sleep 1
    done
    warn "the node did not confirm the reload; check: saucewg logs awg"
}

cmd_add_node() {
    need_root add-node
    require_entry

    local json="" name="" endpoint="" public_key="" psk="" priority="" address=""
    local protocol="" reload=true
    # Parallel to AWG_OBF_PARAMS, so --s3 or --i1 needs no new variable here.
    local -A obf=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            --endpoint) endpoint=$2; shift 2 ;;
            --public-key) public_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --priority) priority=$2; shift 2 ;;
            --address) address=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --s[1-4]|--h[1-4]|--i[1-5]|--jc|--jmin|--jmax)
                obf[$(printf '%s' "${1#--}" | tr '[:lower:]' '[:upper:]')]=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            *) die "unknown option for add-node: $1" ;;
        esac
    done
    [ -z "$protocol" ] || protocol=$(require_protocol "$protocol")

    local node
    if [ -n "$json" ]; then
        [ "$json" = "-" ] && json=$(cat)
        node=$(printf '%s' "$json" | jq -e 'if type == "object" then . else error("not an object") end') \
            || die "--json did not contain a JSON object"
    else
        [ -n "$name" ] || die "--name is required"
        [ -n "$endpoint" ] || die "--endpoint is required (host:port)"
        [ -n "$public_key" ] || die "--public-key is required"
        node=$(jq -n --arg name "$name" --arg endpoint "$endpoint" --arg key "$public_key" \
                     --arg psk "$psk" --arg protocol "$protocol" '
            {name: $name, endpoint: $endpoint, public_key: $key}
            + (if $psk == "" then {} else {preshared_key: $psk} end)
            + (if $protocol == "" then {} else {protocol: $protocol} end)')
        local param
        for param in "${!obf[@]}"; do
            node=$(printf '%s' "$node" | jq --arg k "$(printf '%s' "$param" | tr '[:upper:]' '[:lower:]')" \
                                            --arg v "${obf[$param]}" \
                '. + {($k): (if ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end)}')
        done
    fi
    # A generation named alongside --json wins: the object may have come from a node
    # that has since been moved.
    if [ -n "$protocol" ]; then
        node=$(printf '%s' "$node" | jq --arg p "$protocol" '. + {protocol: $p}')
    fi

    name=$(printf '%s' "$node" | jq -r '.name // ""')
    [ -n "$name" ] || die "the node object needs a name"

    local file uplink_subnet
    file=$(nodes_file)
    uplink_subnet=$(env_get "$ENV_FILE" CASCADE_UPLINK_SUBNET || echo 10.77.0.0/24)

    jq -e --arg n "$name" 'any(.[]; .name == $n)' "$file" >/dev/null 2>&1 \
        && die "an exit node named ${name} already exists"

    # Pin an address and a priority now so removing a node later never renumbers
    # the survivors.
    if [ -z "$address" ] && ! printf '%s' "$node" | jq -e 'has("address")' >/dev/null; then
        local prefix host
        prefix=${uplink_subnet%%/*}
        prefix=${prefix%.*}
        for host in $(seq 2 254); do
            if ! jq -e --arg a "${prefix}.${host}/32" 'any(.[]; .address == $a)' "$file" >/dev/null; then
                address="${prefix}.${host}/32"
                break
            fi
        done
        [ -n "$address" ] || die "no free address left in ${uplink_subnet}"
    fi
    if [ -z "$priority" ] && ! printf '%s' "$node" | jq -e 'has("priority")' >/dev/null; then
        # `.[].priority // 100` would fall through to 100 on an empty list, so the
        # very first node has to be mapped explicitly.
        priority=$(jq '[.[] | .priority // 100] | (max // 0) + 10' "$file")
    fi

    jq --argjson node "$node" --arg address "$address" --arg priority "$priority" '
        . + [$node
             + (if $address == "" then {} else {address: $address} end)
             + (if $priority == "" then {} else {priority: ($priority | tonumber)} end)]
        ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    log "added ${name} to the cascade"

    local uplink_key=""
    if [ "$reload" = true ]; then
        request_reload
        uplink_key=$(uplink_key_for "$name")
    else
        note "the node was not reloaded; apply it with: saucewg reload"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg name "$name" --arg address "$address" --arg key "$uplink_key" \
            '{ok: true, name: $name, address: $address,
              uplink_public_key: (if $key == "" then null else $key end)}'
    else
        note "uplink address    ${address}"
        if [ -n "$uplink_key" ]; then
            note "uplink public key ${uplink_key}"
            note ""
            note "Install it on the exit node with:"
            note "  saucewg node-pair --peer-key ${uplink_key}"
        else
            note ""
            note "Once the cascade is running, pair the exit node with the key from:"
            note "  saucewg uplink-key ${name}"
        fi
    fi
}

cmd_remove_node() {
    need_root remove-node
    require_entry

    local name="" reload=true
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            -*) die "unknown option for remove-node: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -n "$name" ] || die "remove-node needs a node name"

    local file
    file=$(nodes_file)
    jq -e --arg n "$name" 'any(.[]; .name == $n)' "$file" >/dev/null 2>&1 \
        || die "no exit node named ${name}"

    confirm "Remove exit node ${name} from the cascade?" || die "aborted"

    jq --arg n "$name" 'map(select(.name != $n))' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    log "removed ${name} from the cascade"

    if [ "$reload" = true ]; then
        request_reload
    else
        note "the node was not reloaded; apply it with: saucewg reload"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --arg name "$name" '{ok: true, removed: $name}'
}

cmd_list_nodes() {
    require_entry
    local file state
    file=$(nodes_file)

    # The live view lives in the node container. When it is down — or has not
    # applied the list yet — fall back to the file, which is the source of truth
    # anyway. `cmd | column` would always report success, so the state is
    # captured and inspected before anything is printed.
    state=$(compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null) || state=""
    printf '%s' "$state" | jq -e 'has("nodes")' >/dev/null 2>&1 || state=""

    if [ "$JSON_OUTPUT" = true ]; then
        if [ -n "$state" ]; then
            printf '%s' "$state" | jq .
        else
            jq '{nodes: .}' "$file"
        fi
        return
    fi

    if [ -n "$state" ]; then
        printf '%s' "$state" | jq -r '
            "PRIO\tNAME\tIFACE\tSTATUS\tENDPOINT",
            (.nodes | sort_by(.priority)[] |
                "\(.priority)\t\(.name)\t\(.iface)\t" +
                (if .active then "active"
                 elif .healthy then "standby"
                 elif (.peer_public_key == null) then "unpaired"
                 else "down" end) +
                "\t\(.endpoint // "-")")'
    else
        jq -r '"PRIO\tNAME\tENDPOINT",
               (sort_by(.priority // 100)[] |
                   "\(.priority // 100)\t\(.name)\t\(.endpoint // "-")")' "$file"
    fi | column -t -s "$(printf '\t')"
}

uplink_key_for() {
    local name=$1
    compose exec -T awg jq -r --arg n "$name" \
        '.nodes[] | select(.name == $n) | .public_key' /var/run/amneziawg/uplinks.json 2>/dev/null \
        | tr -d '\r\n'
}

cmd_uplink_key() {
    require_entry
    local name="${1:-}"
    if [ -n "$name" ]; then
        local key
        key=$(uplink_key_for "$name")
        [ -n "$key" ] || die "no uplink named ${name} is running"
        if [ "$JSON_OUTPUT" = true ]; then
            jq -n --arg name "$name" --arg key "$key" '{name: $name, public_key: $key}'
        else
            printf '%s\n' "$key"
        fi
        return
    fi
    if [ "$JSON_OUTPUT" = true ]; then
        compose exec -T awg jq '[.nodes[] | {name, public_key}]' /var/run/amneziawg/uplinks.json
    else
        compose exec -T awg jq -r '.nodes[] | "\(.name)\t\(.public_key)"' /var/run/amneziawg/uplinks.json
    fi
}

cmd_reload() {
    require_entry
    request_reload
    [ "$JSON_OUTPUT" = false ] || jq -n '{ok: true}'
}

# Replaces one exit node's entry in the cascade, keeping its address and priority.
#
# This is the entry-node half of a generation change: `saucewg set-protocol` on the
# exit node prints a new pairing object, and the padding and header parameters in it
# have to reach this side or the handshake stops working.
cmd_update_node() {
    need_root update-node
    require_entry

    local json="" name="" endpoint="" protocol="" reload=true
    local -A obf=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            --endpoint) endpoint=$2; shift 2 ;;
            --priority) obf[PRIORITY]=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --s[1-4]|--h[1-4]|--i[1-5]|--jc|--jmin|--jmax)
                obf[$(printf '%s' "${1#--}" | tr '[:lower:]' '[:upper:]')]=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            -*) die "unknown option for update-node: $1" ;;
            *) name=$1; shift ;;
        esac
    done
    [ -z "$protocol" ] || protocol=$(require_protocol "$protocol")

    local patch='{}'
    if [ -n "$json" ]; then
        [ "$json" = "-" ] && json=$(cat)
        patch=$(printf '%s' "$json" | jq -e 'if type == "object" then . else error("not an object") end') \
            || die "--json did not contain a JSON object"
        [ -n "$name" ] || name=$(printf '%s' "$patch" | jq -r '.name // ""')
    fi
    [ -n "$name" ] || die "update-node needs a node name"

    [ -z "$endpoint" ] || patch=$(printf '%s' "$patch" | jq --arg v "$endpoint" '. + {endpoint: $v}')
    [ -z "$protocol" ] || patch=$(printf '%s' "$patch" | jq --arg v "$protocol" '. + {protocol: $v}')
    local param key
    for param in "${!obf[@]}"; do
        key=$(printf '%s' "$param" | tr '[:upper:]' '[:lower:]')
        patch=$(printf '%s' "$patch" | jq --arg k "$key" --arg v "${obf[$param]}" \
            '. + {($k): (if ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end)}')
    done

    local file
    file=$(nodes_file)
    jq -e --arg n "$name" 'any(.[]; .name == $n)' "$file" >/dev/null 2>&1 \
        || die "no exit node named ${name}"

    # The old generation's parameters are dropped rather than overwritten: a leftover
    # S3 would keep this uplink advertising 2.0 to an exit node that no longer does.
    local params_lower
    params_lower=$(printf '%s' "$AWG_OBF_PARAMS" | tr '[:upper:]' '[:lower:]')
    jq --arg n "$name" --argjson patch "$patch" --arg obf "$params_lower" '
        ($obf | split(" ")) as $keys
        | map(if .name == $n
              then (if ($patch | has("protocol")) then delpaths([$keys[] | [.]]) else . end)
                   + ($patch | del(.name))
              else . end)' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    log "updated ${name} in the cascade"

    if [ "$reload" = true ]; then
        request_reload
    else
        note "the node was not reloaded; apply it with: saucewg reload"
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        jq -e --arg n "$name" '.[] | select(.name == $n) | {ok: true} + .' "$file"
    else
        jq -r --arg n "$name" '.[] | select(.name == $n)
            | "protocol \(.protocol // "1.0")\naddress  \(.address // "-")\nendpoint \(.endpoint // "-")"' "$file" \
            | while IFS= read -r line; do note "$line"; done
    fi
}

# ---------------------------------------------------------------------------
# AmneziaWG generation
# ---------------------------------------------------------------------------

# What this node serves right now, and what a client needs to speak to it.
cmd_protocol() {
    require_installed

    local configured active iface params="" signature=""
    configured=$(env_get "$ENV_FILE" AWG_PROTOCOL || true)
    iface=$(env_get "$ENV_FILE" AWG_IFACE || echo awg0)

    # The .params file is what the interface is actually running; .env is only what
    # was asked for, and the two differ until the container has been recreated.
    params=$(compose exec -T awg cat "/etc/amnezia/amneziawg/${iface}.params" 2>/dev/null) || params=""
    active=$(printf '%s' "$params" | sed -n 's/^SERVER_PROTOCOL=//p' | tail -n1)
    signature=$(printf '%s' "$params" | sed -n "s/^SERVER_I1=//p" | tail -n1)
    signature=${signature#\'}; signature=${signature%\'}

    # An interface that predates generation selection records no generation but is
    # serving 1.0 clients, so that is the honest answer rather than a blank.
    if [ -z "$active" ] && [ -n "$params" ]; then active=1.0; fi

    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg role "$(role)" --arg configured "${configured:-}" --arg active "${active:-}" \
              --arg signature "$signature" --arg latest "$AWG_PROTOCOL_LATEST" \
              --arg supported "$AWG_PROTOCOLS" '
            {role: $role,
             protocol: (if $active == "" then null else $active end),
             configured: (if $configured == "" then null else $configured end),
             signature: (if $signature == "" then null else $signature end),
             latest: $latest,
             supported: ($supported | split(" "))}'
        return
    fi

    note "role       $(role)"
    note "serving    AmneziaWG ${active:-<not running>}"
    [ -z "$configured" ] || note "configured AmneziaWG ${configured}"
    [ -z "$signature" ] || note "signature  ${signature}"
    note "supported  ${AWG_PROTOCOLS} (newest on KeeneticOS: ${AWG_PROTOCOL_LATEST})"
    if [ -n "$configured" ] && [ -n "$active" ] && [ "$configured" != "$active" ]; then
        warn "the interface is still on ${active}; apply the change with: saucewg restart"
    fi
}

# Moves this node to another generation. On an exit node the new pairing object is
# printed, because the entry node has to be told the parameters that changed.
cmd_set_protocol() {
    need_root set-protocol
    require_installed

    local protocol="" signature="" restart=true
    while [ $# -gt 0 ]; do
        case "$1" in
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --signature|--cps) signature=$2; shift 2 ;;
            --no-restart) restart=false; shift ;;
            -*) die "unknown option for set-protocol: $1" ;;
            *) protocol=$1; shift ;;
        esac
    done
    [ -n "$protocol" ] || die "set-protocol needs a generation (one of: ${AWG_PROTOCOLS})"
    protocol=$(require_protocol "$protocol")

    local current
    current=$(env_get "$ENV_FILE" AWG_PROTOCOL || true)
    [ -n "$current" ] || current=1.0

    if [ "$(role)" = "entry" ]; then
        confirm "Move the entry node to AmneziaWG ${protocol}? Every client config has to be re-exported and re-imported." \
            || die "aborted"
    fi

    # The parameters both generations share are kept, so a 1.5 to 2.0 move only adds
    # S3, S4 and leaves the padding clients already agree on alone.
    local peers=clients
    [ "$(role)" = "exit" ] && peers=nodes
    load_profile "$ENV_FILE"
    generate_profile "$protocol" "$signature" "$peers"
    store_profile "$ENV_FILE" "$protocol"
    log "configured AmneziaWG ${protocol} (was ${current})"

    if [ "$restart" = false ]; then
        note "not applied yet; recreate the node with: saucewg restart"
        [ "$JSON_OUTPUT" = false ] || jq -n --arg p "$protocol" '{ok: true, protocol: $p, applied: false}'
        return 0
    fi

    step "Applying AmneziaWG ${protocol}"
    compose up -d --force-recreate awg >&2
    wait_for_params

    if [ "$(role)" = "exit" ]; then
        step "The exit node now serves AmneziaWG ${protocol}"
        emit_node_info
        [ "$JSON_OUTPUT" = true ] || {
            note ""
            note "Its padding and headers changed, so the entry node has to be updated:"
            note "  saucewg update-node --json '<the object above>'   # on the entry node"
        }
        return 0
    fi

    step "The entry node now serves AmneziaWG ${protocol}"
    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg p "$protocol" --arg was "$current" \
            '{ok: true, protocol: $p, previous: $was, applied: true}'
    else
        note "Existing clients keep the old profile until their config is re-imported."
        note "Re-download each one from the panel, or with: saucewg shell panel"
        if [ "$protocol" != "1.0" ]; then
            note ""
            note "AmneziaWG ${protocol} needs KeeneticOS 5.1 Alpha 3 or newer on a router."
        fi
    fi
}

# The signature packet presets, so an operator can see what --signature accepts.
cmd_signatures() {
    if [ "$JSON_OUTPUT" = true ]; then
        local name
        for name in $AWG_CPS_PRESETS; do
            jq -n --arg name "$name" --arg spec "$(awg_cps_preset "$name")" \
                  --arg about "$(awg_cps_describe "$name")" \
                  '{name: $name, spec: $spec, description: $about}'
        done | jq -s --arg supported "1.5 2.0" \
            '{presets: ., applies_to: ($supported | split(" "))}'
        return
    fi

    note "Signature packets (I1) disguise the handshake as another protocol."
    note "They are sender-side only, so each end may use a different one."
    note ""
    local name
    for name in $AWG_CPS_PRESETS; do
        printf '%-8s %s\n' "$name" "$(awg_cps_describe "$name")"
        printf '         %s\n' "$(awg_cps_preset "$name")"
    done
    note ""
    note "Used by AmneziaWG 1.5 and 2.0; ignored on 1.0. A literal spec works too:"
    note "  saucewg set-protocol 2.0 --signature '<b 0xdeadbeef><r 64>'"
}

# ---------------------------------------------------------------------------
# Service control
# ---------------------------------------------------------------------------

cmd_up() {
    require_installed
    compose up -d "$@" >&2
    log "started"
}

cmd_down() {
    require_installed
    compose down "$@" >&2
    log "stopped"
}

cmd_restart() {
    require_installed
    compose up -d --force-recreate "$@" >&2
    log "restarted"
}

cmd_status() {
    require_installed
    if [ "$JSON_OUTPUT" = true ]; then
        cmd_info
        return
    fi
    printf '%srole%s      %s\n' "$C_DIM" "$C_OFF" "$(role)" >&2
    printf '%sdirectory%s %s\n' "$C_DIM" "$C_OFF" "$APP_DIR" >&2
    compose ps
}

cmd_logs() {
    require_installed
    local follow=() tail=200 services=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--follow) follow=(-f); shift ;;
            -n|--tail) tail=$2; shift 2 ;;
            *) services+=("$1"); shift ;;
        esac
    done
    compose logs "${follow[@]}" --tail "$tail" ${services[@]+"${services[@]}"}
}

cmd_shell() {
    require_installed
    local service="${1:-}"
    if [ -z "$service" ]; then
        service=awg
        [ "$(role)" = "entry" ] && service=panel
    fi
    compose exec "$service" sh -c 'command -v bash >/dev/null && exec bash || exec sh'
}

cmd_edit() {
    require_installed
    "${EDITOR:-nano}" "$ENV_FILE"
    confirm "Apply the changes now?" && cmd_restart
}

cmd_update() {
    need_root update
    require_installed

    local restart=true
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) IMAGE_TAG=$2; shift 2 ;;
            --no-restart) restart=false; shift ;;
            *) die "unknown option for update: $1" ;;
        esac
    done

    step "Updating the saucewg command"
    install_cli

    step "Refreshing the compose file"
    # Regenerated on every update so a new release can add services or volumes.
    if [ "$(role)" = "entry" ]; then
        write_entry_compose
        env_set "$ENV_FILE" IMAGE_AWG "$(image_ref awg)"
        env_set "$ENV_FILE" IMAGE_PANEL "$(image_ref panel)"
        env_set "$ENV_FILE" IMAGE_WEB "$(image_ref web)"
        env_set "$ENV_FILE" SAUCEWG_TAG "$IMAGE_TAG"
        # Settings introduced after the initial install.
        grep -q '^NODE_REGISTRY_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" NODE_REGISTRY_FILE /etc/saucewg/host/exit-nodes.json
        grep -q '^NODE_PROVISION_ENABLED=' "$ENV_FILE" \
            || env_set "$ENV_FILE" NODE_PROVISION_ENABLED true
        grep -q '^NODE_SSH_KEY_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" NODE_SSH_KEY_FILE /etc/saucewg/host/panel-ssh-key
        grep -q '^NODE_SSH_KEY_ENABLED=' "$ENV_FILE" \
            || env_set "$ENV_FILE" NODE_SSH_KEY_ENABLED true
    else
        write_exit_compose
        env_set "$ENV_FILE" IMAGE_AWG "$(image_ref awg)"
        env_set "$ENV_FILE" SAUCEWG_TAG "$IMAGE_TAG"
    fi

    # An installation from before generations were named is serving 1.0 clients right
    # now, so it is pinned to 1.0 rather than silently moved to the current default.
    # `saucewg set-protocol` is how an operator opts in.
    if ! grep -q '^AWG_PROTOCOL=' "$ENV_FILE"; then
        env_set "$ENV_FILE" AWG_PROTOCOL 1.0
        note "recorded this node as AmneziaWG 1.0; move it with: saucewg set-protocol ${AWG_PROTOCOL_LATEST}"
    fi

    step "Pulling images"
    compose pull --quiet >&2

    local healthy=true
    if [ "$restart" = true ]; then
        step "Restarting"
        compose up -d --remove-orphans >&2
        [ "$(role)" = "entry" ] && wait_for_panel
        wait_for_containers || healthy=false
    fi

    if [ "$healthy" = false ]; then
        warn "the pulled images are running worse than the ones they replaced"
        warn "roll back by pinning the previous tag in ${ENV_FILE}, then: saucewg restart"
    else
        log "updated to ${IMAGE_TAG}"
    fi
    [ "$JSON_OUTPUT" = false ] || jq -n --arg tag "$IMAGE_TAG" --arg version "$SAUCEWG_VERSION" \
        --argjson healthy "$healthy" '{ok: $healthy, tag: $tag, cli_version: $version}'
}

cmd_uninstall() {
    need_root uninstall
    local purge=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --purge) purge=true; shift ;;
            *) die "unknown option for uninstall: $1" ;;
        esac
    done

    if [ ! -f "$COMPOSE_FILE" ]; then
        warn "nothing installed in ${APP_DIR}"
    else
        confirm "Remove SauceWG and its data volumes from this server?" || die "aborted"
        compose down -v --remove-orphans >&2 || true
    fi

    if [ "$purge" = true ]; then
        rm -rf "$APP_DIR"
        rm -f "$CLI_PATH" /etc/sysctl.d/99-saucewg.conf
        log "removed ${APP_DIR} and ${CLI_PATH}"
    else
        log "containers and volumes removed; ${APP_DIR} was kept (use --purge to delete it)"
    fi
    [ "$JSON_OUTPUT" = false ] || jq -n --argjson purged "$purge" '{ok: true, purged: $purged}'
}

# ---------------------------------------------------------------------------
# Panel administration
# ---------------------------------------------------------------------------

cmd_admin_password() {
    need_root admin-password
    require_entry

    local username="" password="" sudo_flag=true
    while [ $# -gt 0 ]; do
        case "$1" in
            --username) username=$2; shift 2 ;;
            --password) password=$2; shift 2 ;;
            --no-sudo) sudo_flag=false; shift ;;
            *) die "unknown option for admin-password: $1" ;;
        esac
    done

    [ -n "$username" ] || username=$(env_get "$ENV_FILE" ADMIN_USERNAME || echo admin)
    [ -n "$password" ] || password=$(rand_secret 18 20)

    local args=(--username "$username" --password-stdin)
    [ "$sudo_flag" = true ] && args+=(--sudo)

    # Through stdin rather than argv: docker's own command line is world-readable
    # in the host's process list.
    printf '%s' "$password" \
        | compose exec -T panel python -m app.cli set-password "${args[@]}" >&2 \
        || die "could not update the password; is the panel running?"
    env_set "$ENV_FILE" ADMIN_USERNAME "$username"
    env_set "$ENV_FILE" ADMIN_PASSWORD "$password"

    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg u "$username" --arg p "$password" '{ok: true, username: $u, password: $p}'
    else
        log "username ${username}"
        log "password ${password}"
    fi
}

# ---------------------------------------------------------------------------
# info / help
# ---------------------------------------------------------------------------

cmd_info() {
    local role_name containers="[]" nodes="null" endpoint="" panel_url=""
    role_name=$(role)

    if [ -f "$COMPOSE_FILE" ]; then
        containers=$(compose ps --format json 2>/dev/null | jq -s -c '
            map({name: (.Service // .Name), state: (.State // ""), status: (.Status // "")})' 2>/dev/null) \
            || containers="[]"
    fi

    if [ "$role_name" = "entry" ] && [ -f "$ENV_FILE" ]; then
        local host port site
        host=$(env_get "$ENV_FILE" AWG_ENDPOINT_HOST || echo "")
        port=$(env_get "$ENV_FILE" AWG_PORT || echo "")
        site=$(env_get "$ENV_FILE" PANEL_SITE_ADDRESS || echo ":80")
        endpoint="${host}:${port}"
        case "$site" in
            :*) panel_url="http://${host}${site#:80}" ;;
            *)  panel_url="https://${site}" ;;
        esac
        nodes=$(compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null) || nodes="null"
    elif [ "$role_name" = "exit" ] && [ -f "$ENV_FILE" ]; then
        endpoint=$(env_get "$ENV_FILE" AWG_PORT || echo "")
    fi

    jq -n \
        --arg version "$SAUCEWG_VERSION" \
        --arg role "$role_name" \
        --arg dir "$APP_DIR" \
        --arg endpoint "$endpoint" \
        --arg panel_url "$panel_url" \
        --argjson containers "${containers:-[]}" \
        --argjson cascade "${nodes:-null}" \
        '{cli_version: $version, role: $role, dir: $dir,
          endpoint: (if $endpoint == "" then null else $endpoint end),
          panel_url: (if $panel_url == "" then null else $panel_url end),
          containers: $containers, cascade: $cascade}'
}

cmd_version() {
    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg v "$SAUCEWG_VERSION" --arg tag "$IMAGE_TAG" '{cli_version: $v, image_tag: $tag}'
    else
        printf 'saucewg %s\n' "$SAUCEWG_VERSION"
    fi
}

usage() {
    cat >&2 <<EOF
saucewg ${SAUCEWG_VERSION} — AmneziaWG cascade (generations ${AWG_PROTOCOLS})

  Installation
    install                  Install the entry node: panel, database and cascade
    install-node             Install an exit node and print its pairing object
                             (both take --protocol ${AWG_PROTOCOL_LATEST} and --signature quic)
    update                   Pull the newest images and recreate the containers
    uninstall [--purge]      Remove the containers and volumes

  Service
    start | up               Start every container
    stop | down              Stop every container
    restart                  Recreate every container
    status | ps              Show what is running
    logs [-f] [-n N] [svc]   Show container logs
    shell [service]          Open a shell inside a container
    edit                     Edit .env and optionally restart

  Cascade (entry node)
    nodes | list-nodes       Exit nodes with health and which one is active
    add-node --json '{…}'    Add an exit node and reload the cascade
    update-node NAME …       Replace an exit node's endpoint or obfuscation profile
    remove-node NAME         Remove an exit node and reload the cascade
                             (all three take --no-reload to batch several edits)
    uplink-key [NAME]        The entry node's public key for an uplink
    reload                   Re-read the exit node list without a restart
    admin-password           Reset the panel admin password

  Exit node
    node-info                Print this node's pairing object
    node-pair --peer-key K   Install the entry node's uplink key here

  AmneziaWG generation
    protocol                 Which generation this node serves
    set-protocol VERSION     Move this node to 1.0, 1.5 or 2.0
                             (--signature PRESET picks the I1 disguise)
    signatures               The signature packet presets --signature accepts

  Other
    info                     Machine-readable status (always JSON)
    version                  Print the CLI version

  Global flags
    --json                   Write one JSON object to stdout; logs go to stderr.
                             add-node and update-node use --json for their payload,
                             so ask for JSON output first: saucewg --json add-node …
    --yes, -y                Never ask for confirmation
    --quiet                  Suppress progress output
    --dir PATH               Installation directory (default /opt/saucewg)
    --tag TAG                Image tag to install (default latest)
    --namespace NS           Image namespace (default v2as)
    --registry HOST          Registry host (default docker.io)

  Install examples
    bash <(curl -fsSL ${RAW_BASE}/saucewg.sh) install --domain panel.example.com
    bash <(curl -fsSL ${RAW_BASE}/saucewg.sh) install-node --name eu-nl --json
    bash <(curl -fsSL ${RAW_BASE}/saucewg.sh) install --protocol 1.0   # older Keenetic

  Generations
    1.0   Jc Jmin Jmax S1 S2 H1-H4       every KeeneticOS from 4.2 Alpha 2 on
    1.5   the same, plus I1              KeeneticOS 5.1 Alpha 3 and newer
    2.0   the same, plus I1, S3 and S4   KeeneticOS 5.1 Alpha 3 and newer
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    local command="" args=() command_owns_flags=false

    while [ $# -gt 0 ]; do
        # `add-node --json '{…}'` takes its payload with a flag that is otherwise
        # global, so once that command is named every remaining argument is its own.
        if [ "$command_owns_flags" = true ]; then args+=("$1"); shift; continue; fi
        case "$1" in
            --json) JSON_OUTPUT=true; shift ;;
            -y|--yes) ASSUME_YES=true; shift ;;
            --quiet) QUIET=true; shift ;;
            --dir) APP_DIR=$2; shift 2 ;;
            --tag) IMAGE_TAG=$2; shift 2 ;;
            --namespace) NAMESPACE=$2; shift 2 ;;
            --registry) REGISTRY=$2; shift 2 ;;
            --image-prefix) IMAGE_PREFIX=$2; shift 2 ;;
            -h|--help|help) usage; exit 0 ;;
            # Marzban-style separator: `bash script.sh @ install` also works.
            @) shift ;;
            *)
                if [ -z "$command" ]; then
                    command=$1
                    case "$command" in add-node|update-node) command_owns_flags=true ;; esac
                else
                    args+=("$1")
                fi
                shift
                ;;
        esac
    done

    ENV_FILE="${APP_DIR}/.env"
    COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
    ROLE_FILE="${APP_DIR}/.role"
    CONFIG_DIR="${APP_DIR}/config"
    NODES_FILE="${CONFIG_DIR}/exit-nodes.json"

    set -- ${args[@]+"${args[@]}"}

    case "$command" in
        install)          cmd_install "$@" ;;
        install-node)     cmd_install_node "$@" ;;
        update|upgrade)   cmd_update "$@" ;;
        uninstall)        cmd_uninstall "$@" ;;
        up|start)         cmd_up "$@" ;;
        down|stop)        cmd_down "$@" ;;
        restart)          cmd_restart "$@" ;;
        status|ps)        cmd_status "$@" ;;
        logs)             cmd_logs "$@" ;;
        shell|cli)        cmd_shell "$@" ;;
        edit)             cmd_edit "$@" ;;
        list-nodes|nodes) cmd_list_nodes "$@" ;;
        add-node)         cmd_add_node "$@" ;;
        update-node)      cmd_update_node "$@" ;;
        remove-node)      cmd_remove_node "$@" ;;
        uplink-key)       cmd_uplink_key "$@" ;;
        reload)           cmd_reload "$@" ;;
        admin-password)   cmd_admin_password "$@" ;;
        node-info)        cmd_node_info "$@" ;;
        node-pair)        cmd_node_pair "$@" ;;
        protocol)         cmd_protocol "$@" ;;
        set-protocol)     cmd_set_protocol "$@" ;;
        signatures|cps)   cmd_signatures "$@" ;;
        info)             cmd_info "$@" ;;
        version)          cmd_version "$@" ;;
        "")               usage; exit 1 ;;
        *)                printf '%s✗%s unknown command: %s\n\n' "$C_ERR" "$C_OFF" "$command" >&2; usage; exit 1 ;;
    esac
}

main "$@"
