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

SAUCEWG_VERSION="1.5.0"

SAUCEWG_REPO="${SAUCEWG_REPO:-V2as/SauceWG}"
SAUCEWG_REF="${SAUCEWG_REF:-main}"
# Where this script publishes itself. Overridable as a whole for a mirror that is not
# GitHub at all, the same way SAUCEWG_REGISTRY moves the images.
RAW_BASE="${SAUCEWG_RAW_BASE:-https://raw.githubusercontent.com/${SAUCEWG_REPO}/${SAUCEWG_REF}}"

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
ROUTES_FILE="${CONFIG_DIR}/direct-routes.json"
# Deliberately not called BYPASS_FILE: that is the name the node container's own
# setting has, and compose interpolates from this process's environment as well as
# from the .env, so the two must not be able to collide.
BYPASS_LIST_FILE="${CONFIG_DIR}/bypass.json"
# Same reasoning as above: TORRENT_BLOCK_FILE is the container's own setting.
TORRENT_SWITCH_FILE="${CONFIG_DIR}/torrent-block.json"

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

# The server's own global IPv6 address, or nothing when it has none.
#
# Asked of the network first and the echo services second. A VPS with one static
# address knows it locally and answers instantly, and an echo service forced onto
# IPv6 is the only way to learn it behind NAT64 or a tunnel broker — but it is also
# the thing that hangs for six seconds per provider on a host with no IPv6 at all,
# which is most of them, so it is not reached unless there is a route to try it
# over.
public_ip6() {
    local ip url
    ip=$(ip -6 -o addr show scope global 2>/dev/null \
        | awk '$3 == "inet6" {split($4, a, "/"); print a[1]; exit}') || ip=""
    case $ip in
        ''|f[cd]*) ;;
        *) printf '%s' "$ip"; return 0 ;;
    esac

    ip -6 route show default 2>/dev/null | grep -q . || return 1
    for url in https://api6.ipify.org https://v6.ident.me https://icanhazip.com; do
        ip=$(curl -fsS -6 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

# 4 for an IPv4 literal, 6 for an IPv6 one, empty for a hostname — which is not
# resolved here, because the family it answers with is not ours to assume.
ip_family() {
    local value=${1:-}
    case $value in
        '') return 0 ;;
        *:*) printf '6'; return 0 ;;
        *[!0-9.]*) return 0 ;;
        *.*.*.*) printf '4' ;;
    esac
}

# host:port the way amneziawg-tools wants it written, which for IPv6 means the
# address in brackets. An endpoint that reaches a .conf unbracketed is read as a
# truncated address with the last group taken for the port, and the tunnel never
# handshakes.
endpoint_format() {
    local host=$1 port=${2:-}
    [ -n "$host" ] || return 0
    [ "$(ip_family "$host")" != 6 ] || host="[${host}]"
    if [ -n "$port" ]; then
        printf '%s:%s' "$host" "$port"
    else
        printf '%s' "$host"
    fi
}

# The host out of an endpoint, brackets removed.
endpoint_host() {
    local value=${1:-}
    case $value in
        '') ;;
        \[*\]:*) value=${value%%\]:*}; printf '%s' "${value#\[}" ;;
        \[*\]) value=${value%\]}; printf '%s' "${value#\[}" ;;
        *:*:*) printf '%s' "$value" ;;
        *:*) printf '%s' "${value%:*}" ;;
        *) printf '%s' "$value" ;;
    esac
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

# ---------------------------------------------------------------------------
# Address families
# ---------------------------------------------------------------------------
#
# The link between an entry node and its exit nodes carries IPv4 out of the box.
# Adding IPv6 to it is two separate choices, and conflating them is the mistake
# worth naming here:
#
#   the endpoint family   which address the tunnel is dialled over, i.e. what a
#                         censor between the two servers sees
#   the bridge family     which families travel inside the tunnel, i.e. what a
#                         destination on the far side sees
#
# They are independent. An exit node reached over IPv4 can carry IPv6 for its
# clients, and one reached over IPv6 can carry nothing but IPv4.

# ULA by default, because the bridge is not meant to be reachable from outside.
# fd00:77::/64 pairs with 10.77.0.0/24 so the two halves read as one link.
CASCADE_UPLINK_SUBNET6_DEFAULT="fd00:77::/64"

# Uplink ports are counted up from here by host number, so the first exit node on
# 10.77.0.2 listens on 51822. Clear of the node's own port, which defaults to 443.
CASCADE_UPLINK_PORT_BASE_DEFAULT=51820

# The whole range the uplinks can be given, which is what gets opened in the
# firewall: one rule that stays correct when an exit node is added, rather than a
# rule per node and a trap for whoever adds the next one.
uplink_port_range() {
    printf '%s %s' "$(($1 + 2))" "$(($1 + 254))"
}

require_port_base() {
    local base=${1:-}
    case $base in
        ''|no|off|false) printf '' ;;
        auto|yes|on|true) printf '%s' "$CASCADE_UPLINK_PORT_BASE_DEFAULT" ;;
        *[!0-9]*) die "--uplink-port-base takes a port number, auto, or none" ;;
        *)
            [ "$base" -ge 1024 ] && [ "$((base + 254))" -le 65535 ] \
                || die "--uplink-port-base must leave room for 254 ports below 65535"
            printf '%s' "$base"
            ;;
    esac
}

require_endpoint_family() {
    case $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]') in
        ''|auto|any) printf 'auto' ;;
        4|v4|ipv4|inet) printf '4' ;;
        6|v6|ipv6|inet6) printf '6' ;;
        *) die "--endpoint-family takes auto, 4 or 6, not ${1}" ;;
    esac
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

# True when this script *is* the installed command, so install_cli has nothing to copy
# over it.
cli_is_installed_copy() {
    [ "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" = "$(readlink -f "$CLI_PATH" 2>/dev/null)" ]
}

# `saucewg update` pulls new images, but install_cli cannot hand it a newer copy of
# itself: it is reading the file it would have to overwrite. That matters because the
# compose file and the settings a release adds to .env are written by *this* script, not
# by the images — so an update run from an old CLI leaves a server running new containers
# configured the way the previous release configured them, which is how a new default
# silently does not arrive. So fetch the published script and let cmd_update hand the
# rest of the run over to it. Prints the version it installed.
#
# Whatever the mirror publishes wins, downgrade included: a fleet pinned with SAUCEWG_REF
# is asking for that ref, not for the newest thing in existence.
#
# All of this is best-effort. A mirror that cannot be reached, or a download that does
# not survive its own syntax check, leaves the old script to finish the update; that is
# the outcome worth warning about, but not one worth abandoning an update over.
cli_self_update() {
    local published tmp
    [ "${SAUCEWG_SELF_UPDATED:-}" = 1 ] && return 1
    cli_is_installed_copy || return 1

    tmp="${CLI_PATH}.new.$$"
    curl -fsSL --max-time 60 "${RAW_BASE}/saucewg.sh" -o "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    published=$(sed -n 's/^SAUCEWG_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -n1)
    # A truncated download and a mirror serving an error page both land here.
    if [ -z "$published" ] || ! bash -n "$tmp" 2>/dev/null; then
        warn "the copy of saucewg at ${RAW_BASE} did not arrive intact; keeping this one"
        rm -f "$tmp"
        return 1
    fi
    if [ "$published" = "$SAUCEWG_VERSION" ]; then
        rm -f "$tmp"
        return 1
    fi

    # A rename rather than a copy: bash reads a script as it runs it, so writing over the
    # file this process is reading rewrites the rest of the run out from under it.
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$CLI_PATH" 2>/dev/null || {
        warn "could not replace ${CLI_PATH} with ${published}; continuing with ${SAUCEWG_VERSION}"
        rm -f "$tmp"
        return 1
    }
    printf '%s' "$published"
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
      # Both empty by default so the node can tell "not chosen" from "chosen": an
      # .env written before CASCADE_FALLBACK existed keeps its kill switch.
      CASCADE_FALLBACK: ${CASCADE_FALLBACK:-}
      CASCADE_KILLSWITCH: ${CASCADE_KILLSWITCH:-}
      CASCADE_NODES_JSON: ${CASCADE_NODES_JSON:-}
      CASCADE_NODES_FILE: ${CASCADE_NODES_FILE:-/etc/amnezia/host/exit-nodes.json}
      CASCADE_DIRECT_ROUTES: ${CASCADE_DIRECT_ROUTES:-}
      CASCADE_DIRECT_FILE: ${CASCADE_DIRECT_FILE:-/etc/amnezia/host/direct-routes.json}
      # Destinations a censor blocks by refusing the TCP handshake to their IPv4
      # rather than by taking the route away, which the entry node reopens itself.
      # `auto` engages only while the entry node is carrying client traffic.
      BYPASS_MODE: ${BYPASS_MODE:-auto}
      BYPASS_GROUPS: ${BYPASS_GROUPS:-telegram}
      BYPASS_ROUTES: ${BYPASS_ROUTES:-}
      BYPASS_FILE: ${BYPASS_FILE:-/etc/amnezia/host/bypass.json}
      BYPASS_PORT: ${BYPASS_PORT:-8646}
      BYPASS_ATTEMPTS: ${BYPASS_ATTEMPTS:-96}
      BYPASS_PARALLEL: ${BYPASS_PARALLEL:-6}
      # BitTorrent, blocked in what this node forwards, because a swarm sees the
      # address of whichever server carries it out and a datacentre answers a
      # copyright notice by suspending that server. Empty leaves the decision to
      # the file the panel writes.
      TORRENT_BLOCK: ${TORRENT_BLOCK:-}
      TORRENT_BLOCK_FILE: ${TORRENT_BLOCK_FILE:-/etc/amnezia/host/torrent-block.json}
      TORRENT_TCP_PORTS: ${TORRENT_TCP_PORTS:-}
      TORRENT_UDP_PORTS: ${TORRENT_UDP_PORTS:-}
      CASCADE_UPLINK_SUBNET: ${CASCADE_UPLINK_SUBNET:-10.77.0.0/24}
      # The IPv6 half of the link to the exit nodes. Empty is a cascade that
      # carries IPv4 only, which is what every installation made before this
      # existed is, and turning it on is the operator's decision rather than
      # something an update makes for them.
      CASCADE_UPLINK_SUBNET6: ${CASCADE_UPLINK_SUBNET6:-}
      # Which endpoint to dial an exit node over when it publishes both: auto, 4
      # or 6. `auto` prefers IPv6 when this node has IPv6, because an entry node's
      # IPv4 is the address a blocklist has.
      CASCADE_ENDPOINT_FAMILY: ${CASCADE_ENDPOINT_FAMILY:-auto}
      # Fixed ports for the uplinks, so an exit node can dial this node rather than
      # only being dialled by it. Empty leaves the port to the kernel.
      CASCADE_UPLINK_PORT_BASE: ${CASCADE_UPLINK_PORT_BASE:-}
      CASCADE_PROBE_ENABLED: ${CASCADE_PROBE_ENABLED:-true}
      CASCADE_PROBE_TARGET: ${CASCADE_PROBE_TARGET:-1.1.1.1}
      CASCADE_PROBE_TARGET6: ${CASCADE_PROBE_TARGET6:-2606:4700:4700::1111}
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
      # The same failover tuning the node container runs on: the panel checks every
      # health flag it reads against the handshake published beside it.
      CASCADE_PROBE_INTERVAL: ${CASCADE_PROBE_INTERVAL:-10}
      CASCADE_FAIL_THRESHOLD: ${CASCADE_FAIL_THRESHOLD:-3}
      CASCADE_HANDSHAKE_TIMEOUT: ${CASCADE_HANDSHAKE_TIMEOUT:-180}
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
      ROUTES_REGISTRY_FILE: ${ROUTES_REGISTRY_FILE:-/etc/saucewg/host/direct-routes.json}
      BYPASS_REGISTRY_FILE: ${BYPASS_REGISTRY_FILE:-/etc/saucewg/host/bypass.json}
      TORRENT_REGISTRY_FILE: ${TORRENT_REGISTRY_FILE:-/etc/saucewg/host/torrent-block.json}
      NODE_PROVISION_ENABLED: ${NODE_PROVISION_ENABLED:-true}
      NODE_DEFAULT_PORT: ${NODE_DEFAULT_PORT:-51820}
      NODE_SSH_TIMEOUT_SECONDS: ${NODE_SSH_TIMEOUT_SECONDS:-900}
      NODE_SSH_QUERY_TIMEOUT_SECONDS: ${NODE_SSH_QUERY_TIMEOUT_SECONDS:-60}
      NODE_SSH_KEY_FILE: ${NODE_SSH_KEY_FILE:-/etc/saucewg/host/panel-ssh-key}
      NODE_SSH_KEY_ENABLED: ${NODE_SSH_KEY_ENABLED:-true}
      NODE_RECOVERY_ENABLED: ${NODE_RECOVERY_ENABLED:-true}
      NODE_RECOVERY_GRACE_SECONDS: ${NODE_RECOVERY_GRACE_SECONDS:-300}
      NODE_RECOVERY_INTERVAL_SECONDS: ${NODE_RECOVERY_INTERVAL_SECONDS:-60}
      NODE_RECOVERY_MAX_ATTEMPTS: ${NODE_RECOVERY_MAX_ATTEMPTS:-6}
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
      # This exit node's side of the IPv6 half of the bridge. Empty is an exit
      # node that carries IPv4 only, and the entry node reports it as such rather
      # than treating it as broken.
      AWG_SUBNET6: ${AWG_SUBNET6:-}
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
      # Set to dial the entry node from here instead of waiting to be dialled,
      # for a path that carries what this node sends but not what it is sent.
      AWG_PEER_ENDPOINT: ${AWG_PEER_ENDPOINT:-}
      AWG_PEER_KEEPALIVE: ${AWG_PEER_KEEPALIVE:-25}
      AWG_PEER_ALLOWED_IPS: ${AWG_PEER_ALLOWED_IPS:-10.77.0.0/24}
      WAN_IFACE: ${WAN_IFACE:-}
      TORRENT_BLOCK: ${TORRENT_BLOCK:-}
      TORRENT_BLOCK_FILE: ${TORRENT_BLOCK_FILE:-/etc/amnezia/host/torrent-block.json}
      TORRENT_TCP_PORTS: ${TORRENT_TCP_PORTS:-}
      TORRENT_UDP_PORTS: ${TORRENT_UDP_PORTS:-}
    volumes:
      - awg-config:/etc/amnezia/amneziawg
      - awg-run:/var/run/amneziawg
      # No panel on an exit node, so this only carries what saucewg.sh writes into
      # it — which is what lets `saucewg torrents` change the setting here without
      # recreating the container.
      - ./config:/etc/amnezia/host:ro

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
    local uplink_subnet6="" endpoint_family=auto uplink_port_base=""
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
            # The IPv6 half of the link to the exit nodes. `--uplink-subnet6 auto`
            # takes the default ULA prefix, which is what anyone who just wants it
            # on means; a prefix of your own goes here instead.
            --uplink-subnet6) uplink_subnet6=$2; shift 2 ;;
            # Fixed ports for the uplinks, so an exit node can dial inwards.
            # `--uplink-port-base auto` takes the default.
            --uplink-port-base) uplink_port_base=$2; shift 2 ;;
            --endpoint-family) endpoint_family=$2; shift 2 ;;
            --endpoint-host|--host) endpoint_host=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --signature|--cps) signature=$2; shift 2 ;;
            --no-start) start=false; shift ;;
            --reinstall) reinstall=true; shift ;;
            *) die "unknown option for install: $1" ;;
        esac
    done

    case $uplink_subnet6 in
        auto|yes|on|true) uplink_subnet6=$CASCADE_UPLINK_SUBNET6_DEFAULT ;;
        no|off|false) uplink_subnet6="" ;;
    esac
    uplink_port_base=$(require_port_base "$uplink_port_base")
    endpoint_family=$(require_endpoint_family "$endpoint_family")

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
    # On from the start. A node that has never forwarded a torrent has nothing to
    # lose by it, and the one that has is already the subject of a notice.
    [ -f "$TORRENT_SWITCH_FILE" ] || torrent_switch_write true on

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
# While every exit node is down: direct = this entry node carries client traffic
# until one recovers, block = drop it. See: saucewg fallback
CASCADE_FALLBACK=direct
CASCADE_NODES_FILE=/etc/amnezia/host/exit-nodes.json
# Destinations that skip the cascade. See: saucewg routes
CASCADE_DIRECT_FILE=/etc/amnezia/host/direct-routes.json
CASCADE_DIRECT_ROUTES=
CASCADE_UPLINK_SUBNET=${uplink_subnet}
# The IPv6 half of the link to the exit nodes, which is what lets an exit node
# reach the IPv6 internet on behalf of this one. Empty carries IPv4 only.
# See: saucewg bridge
CASCADE_UPLINK_SUBNET6=${uplink_subnet6}
# Which endpoint to dial an exit node over when it publishes both: auto, 4 or 6.
# auto prefers IPv6 when this node has IPv6 — an entry node's IPv4 is the address
# a blocklist has, and the same exit node answers on IPv6 through filters that were
# never built to look there.
CASCADE_ENDPOINT_FAMILY=${endpoint_family}
# Where the uplinks listen, one port per exit node counted up from here, so that an
# exit node can dial this node instead of only being dialled. Empty leaves the port
# to the kernel, which is what an uplink has always done. See: saucewg dial-in
CASCADE_UPLINK_PORT_BASE=${uplink_port_base}

# Destinations blocked by dropping the TCP handshake to their IPv4, which this
# entry node reopens over IPv6 or by retrying. auto engages only while clients are
# leaving through here. See: saucewg bypass
BYPASS_MODE=auto
BYPASS_GROUPS=telegram
BYPASS_FILE=/etc/amnezia/host/bypass.json
BYPASS_ROUTES=
BYPASS_PORT=8646
# The handshake budget for one connection, and how many go out at once. Several at
# a time is what makes a connection to a destination whose handshakes are being
# dropped take under a second rather than ten.
BYPASS_ATTEMPTS=96
BYPASS_PARALLEL=6

# BitTorrent, blocked in the traffic this node forwards. A swarm sees the address
# of whichever server carries it out, and a datacentre answers a copyright notice
# by suspending that server rather than by asking who was behind it. Leave this
# empty and the switch lives in config/torrent-block.json, which is what the panel
# and `saucewg torrents` write; off, on or strict here pins it and takes the switch
# out of the UI.
TORRENT_BLOCK=
TORRENT_BLOCK_FILE=/etc/amnezia/host/torrent-block.json
# What strict mode still allows out. Empty means the built-in lists.
TORRENT_TCP_PORTS=
TORRENT_UDP_PORTS=

CASCADE_PROBE_ENABLED=true
CASCADE_PROBE_TARGET=1.1.1.1
# Where the IPv6 half of the bridge is probed, when there is one. Its result is
# reported rather than acted on: clients are IPv4, so an exit node whose IPv6 is
# broken is still carrying everything it is asked to.
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
CLIENT_SIGNATURE=

COLLECTOR_INTERVAL_SECONDS=10
SYNC_INTERVAL_SECONDS=30
ONLINE_TIMEOUT_SECONDS=180
USAGE_BUCKET_MINUTES=60
USAGE_RETENTION_DAYS=90
SUBSCRIPTION_URL_PREFIX=

NODE_REGISTRY_FILE=/etc/saucewg/host/exit-nodes.json
ROUTES_REGISTRY_FILE=/etc/saucewg/host/direct-routes.json
BYPASS_REGISTRY_FILE=/etc/saucewg/host/bypass.json
TORRENT_REGISTRY_FILE=/etc/saucewg/host/torrent-block.json
NODE_PROVISION_ENABLED=true
NODE_DEFAULT_PORT=51820
NODE_SSH_TIMEOUT_SECONDS=900
NODE_SSH_KEY_FILE=/etc/saucewg/host/panel-ssh-key
NODE_SSH_KEY_ENABLED=true
NODE_RECOVERY_ENABLED=true
NODE_RECOVERY_GRACE_SECONDS=300
NODE_RECOVERY_INTERVAL_SECONDS=60
NODE_RECOVERY_MAX_ATTEMPTS=6
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

    local name="" port=51820 subnet=10.77.0.0/24 peer_allowed=""
    local subnet6="" endpoint_host6=""
    local peer_key="" psk="" endpoint_host="" reinstall=false start=true
    local protocol="" signature="" requested_protocol=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name=$2; shift 2 ;;
            --port) port=$2; shift 2 ;;
            --subnet) subnet=$2; shift 2 ;;
            # This node's side of the IPv6 half of the bridge. `auto` takes the
            # default ULA prefix, which has to be the same one the entry node uses.
            --subnet6) subnet6=$2; shift 2 ;;
            --peer-allowed-ips) peer_allowed=$2; shift 2 ;;
            --peer-key) peer_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --psk-stdin) psk=$(read_stdin_secret); shift ;;
            --endpoint-host|--host) endpoint_host=$2; shift 2 ;;
            --endpoint-host6|--host6) endpoint_host6=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; requested_protocol=true; shift 2 ;;
            --signature|--cps) signature=$2; requested_protocol=true; shift 2 ;;
            --no-start) start=false; shift ;;
            --reinstall) reinstall=true; shift ;;
            *) die "unknown option for install-node: $1" ;;
        esac
    done

    [ -n "$name" ] || name=$(hostname -s 2>/dev/null || echo exit)
    protocol=$(require_protocol "${protocol:-$AWG_PROTOCOL_LATEST}")

    case $subnet6 in
        auto|yes|on|true) subnet6=$CASCADE_UPLINK_SUBNET6_DEFAULT ;;
        no|off|false) subnet6="" ;;
    esac
    # AllowedIPs is the inbound filter as well as the route, so it has to name
    # every family the bridge carries or the node drops what it is sent.
    if [ -z "$peer_allowed" ]; then
        peer_allowed=$subnet
        [ -z "$subnet6" ] || peer_allowed="${subnet}, ${subnet6}"
    fi

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
# This node's side of the IPv6 half of the bridge: what the entry node reaches the
# IPv6 internet through. Empty carries IPv4 only, and has to match whether the
# entry node has CASCADE_UPLINK_SUBNET6 set.
AWG_SUBNET6=${subnet6}
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
# Where to dial the entry node, when this node reaches inwards rather than waiting
# to be dialled. Empty is the usual arrangement. See: saucewg node-pair --peer-endpoint
AWG_PEER_ENDPOINT=
AWG_PEER_KEEPALIVE=25
WAN_IFACE=

# BitTorrent, blocked in the traffic this node forwards. This is the server a
# swarm sees and the one a datacentre suspends over a copyright notice. Empty
# takes the setting from config/torrent-block.json instead, which is what
# \`saucewg torrents\` writes and what applies without recreating the container.
TORRENT_BLOCK=
TORRENT_BLOCK_FILE=/etc/amnezia/host/torrent-block.json
TORRENT_TCP_PORTS=
TORRENT_UDP_PORTS=
EOF
        chmod 600 "$ENV_FILE"
        mkdir -p "$CONFIG_DIR"
        # This is the address a swarm sees and the one a datacentre suspends, so
        # the guard is on before the node has carried anything.
        [ -f "$TORRENT_SWITCH_FILE" ] || torrent_switch_write true on
        write_exit_compose
        install_cli
    fi

    [ -z "$peer_key" ] || env_set "$ENV_FILE" AWG_PEER_PUBLIC_KEY "$peer_key"
    [ -z "$psk" ] || env_set "$ENV_FILE" AWG_PEER_PSK "$psk"
    [ -z "$endpoint_host" ] || env_set "$ENV_FILE" SAUCEWG_ENDPOINT_HOST "$endpoint_host"
    [ -z "$endpoint_host6" ] || env_set "$ENV_FILE" SAUCEWG_ENDPOINT_HOST6 "$endpoint_host6"

    # Re-running the installer on a node that is already up is how an IPv6 bridge
    # gets added to one, so --subnet6 is applied to the .env that was kept. The
    # peer's AllowedIPs follow from it inside the container, which is what keeps an
    # .env written before this existed working unedited.
    if [ -n "$subnet6" ] && [ "$(env_get "$ENV_FILE" AWG_SUBNET6)" != "$subnet6" ]; then
        env_set "$ENV_FILE" AWG_SUBNET6 "$subnet6"
        note "the IPv6 half of the bridge is ${subnet6} on this node"
    fi

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
# Takes a single port, or "from to" for a range. The two firewalls spell a range
# differently, which is the only reason this knows about ranges at all.
open_node_port() {
    local from=$1 to=${2:-} ufw_spec firewalld_spec label
    if [ -n "$to" ]; then
        ufw_spec="${from}:${to}"
        firewalld_spec="${from}-${to}"
        label="${from}-${to}"
    else
        ufw_spec=$from
        firewalld_spec=$from
        label=$from
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw allow "${ufw_spec}/udp" >/dev/null 2>&1 && log "opened ${label}/udp in ufw" || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${firewalld_spec}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 && log "opened ${label}/udp in firewalld" || true
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

    local iface params host host6 port name endpoint endpoint6 subnet6
    iface=$(env_get "$ENV_FILE" AWG_IFACE || echo awg0)
    params=$(compose exec -T awg cat "/etc/amnezia/amneziawg/${iface}.params" 2>/dev/null) \
        || die "could not read the node parameters; is the node running?"

    name=$(env_get "$ENV_FILE" SAUCEWG_NODE_NAME || true)
    [ -n "$name" ] || name=$(hostname -s 2>/dev/null || echo exit)
    port=$(printf '%s' "$params" | sed -n 's/^SERVER_PORT=//p')
    subnet6=$(printf '%s' "$params" | sed -n 's/^SERVER_SUBNET6=//p' | tr -d "'")

    # Both endpoints are reported, because the entry node decides which to dial and
    # can move between them when one stops answering. amneziawg-go binds a socket of
    # each family, so a node that has IPv6 is already reachable over it — there is
    # nothing to switch on here, only an address to tell the entry node about.
    #
    # An IPv6-only VPS has no IPv4 to report, and that is not an error: a node with
    # one endpoint is dialled over the family it has.
    host=$(env_get "$ENV_FILE" SAUCEWG_ENDPOINT_HOST || true)
    host6=$(env_get "$ENV_FILE" SAUCEWG_ENDPOINT_HOST6 || true)
    if [ -z "$host" ] && [ -z "$host6" ]; then
        host=$(public_ip) || host=""
        host6=$(public_ip6) || host6=""
        [ -n "$host" ] || [ -n "$host6" ] \
            || die "could not detect a public address; pass --endpoint-host or --endpoint-host6"
    fi
    # A single --endpoint-host carrying an IPv6 literal is the IPv6 endpoint,
    # whichever flag it arrived through.
    if [ "$(ip_family "$host")" = 6 ] && [ -z "$host6" ]; then
        host6=$host
        host=""
    fi
    endpoint=$(endpoint_format "$host" "$port")
    endpoint6=$(endpoint_format "$host6" "$port")

    # Only the parameters the node's generation actually carries are reported: an
    # extra S3 in the list would have the entry node build a 2.0 uplink towards an
    # exit node that speaks 1.0, and the handshake would never complete.
    local json
    json=$(printf '%s' "$params" | jq -R -s \
        --arg name "$name" --arg endpoint "$endpoint" --arg endpoint6 "$endpoint6" \
        --arg port "$port" --arg subnet6 "$subnet6" \
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
            endpoint: (if $endpoint == "" then null else $endpoint end),
            endpoint6: (if $endpoint6 == "" then null else $endpoint6 end),
            public_key: $p.SERVER_PUBLIC_KEY,
            port: ($port | tonumber),
            protocol: ($p.SERVER_PROTOCOL // "1.0")
          }
        + (if $subnet6 == "" then {} else {subnet6: $subnet6} end)
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
    local peer_endpoint="" keepalive="" set_endpoint=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --peer-key|--key) peer_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --psk-stdin) psk=$(read_stdin_secret); shift ;;
            --no-psk) clear_psk=true; shift ;;
            # Dial the entry node from here instead of waiting to be dialled. For
            # the case the entry node cannot reach this one but this one can reach
            # it, which is what one-directional filtering looks like.
            --peer-endpoint|--dial) peer_endpoint=$2; set_endpoint=true; shift 2 ;;
            --no-peer-endpoint|--no-dial) peer_endpoint=""; set_endpoint=true; shift ;;
            --keepalive) keepalive=$2; shift 2 ;;
            *) die "unknown option for node-pair: $1" ;;
        esac
    done
    [ -n "$peer_key" ] || die "--peer-key is required"

    case $peer_endpoint in
        '') ;;
        *:*) ;;
        *) die "--peer-endpoint takes host:port, like 203.0.113.10:51822" ;;
    esac
    case $keepalive in
        ''|*[!0-9]*) [ -z "$keepalive" ] || die "--keepalive takes a number of seconds" ;;
    esac

    env_set "$ENV_FILE" AWG_PEER_PUBLIC_KEY "$peer_key"
    [ -z "$psk" ] || env_set "$ENV_FILE" AWG_PEER_PSK "$psk"
    [ "$clear_psk" = false ] || env_set "$ENV_FILE" AWG_PEER_PSK ""
    [ "$set_endpoint" = false ] || env_set "$ENV_FILE" AWG_PEER_ENDPOINT "$peer_endpoint"
    [ -z "$keepalive" ] || env_set "$ENV_FILE" AWG_PEER_KEEPALIVE "$keepalive"

    log "pairing with the entry node and restarting"
    compose up -d --force-recreate awg >&2
    wait_for_params

    local dialling
    dialling=$(env_get "$ENV_FILE" AWG_PEER_ENDPOINT || true)
    if [ "$JSON_OUTPUT" = true ]; then
        jq -n --arg key "$peer_key" --arg dial "$dialling" \
            '{ok: true, paired: true, peer_public_key: $key,
              peer_endpoint: (if $dial == "" then null else $dial end)}'
    else
        log "paired with ${peer_key}"
        if [ -n "$dialling" ]; then
            note "this node dials ${dialling} rather than waiting to be dialled"
        fi
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

    local json="" name="" endpoint="" endpoint6="" family="" public_key="" psk=""
    local priority="" address="" address6=""
    local protocol="" reload=true
    # Parallel to AWG_OBF_PARAMS, so --s3 or --i1 needs no new variable here.
    local -A obf=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            --endpoint|--endpoint4) endpoint=$2; shift 2 ;;
            --endpoint6) endpoint6=$2; shift 2 ;;
            # Which of the two to dial: auto, 4 or 6. Per node, overriding
            # CASCADE_ENDPOINT_FAMILY.
            --family|--endpoint-family) family=$2; shift 2 ;;
            --public-key) public_key=$2; shift 2 ;;
            --psk) psk=$2; shift 2 ;;
            --priority) priority=$2; shift 2 ;;
            --address) address=$2; shift 2 ;;
            # This uplink's address on the IPv6 half of the bridge. `none` keeps
            # one node off it while the rest of the cascade uses it.
            --address6) address6=$2; shift 2 ;;
            --protocol|--awg-version) protocol=$2; shift 2 ;;
            --s[1-4]|--h[1-4]|--i[1-5]|--jc|--jmin|--jmax)
                obf[$(printf '%s' "${1#--}" | tr '[:lower:]' '[:upper:]')]=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            *) die "unknown option for add-node: $1" ;;
        esac
    done
    [ -z "$protocol" ] || protocol=$(require_protocol "$protocol")
    [ -z "$family" ] || family=$(require_endpoint_family "$family")
    # An IPv6 literal given as the plain endpoint is the IPv6 endpoint. Typing one
    # address into one field is what an operator does, and the alternative is a
    # tunnel configured with a truncated address that never handshakes.
    if [ "$(ip_family "$(endpoint_host "$endpoint")")" = 6 ] && [ -z "$endpoint6" ]; then
        endpoint6=$endpoint
        endpoint=""
    fi

    local node
    if [ -n "$json" ]; then
        [ "$json" = "-" ] && json=$(cat)
        node=$(printf '%s' "$json" | jq -e 'if type == "object" then . else error("not an object") end') \
            || die "--json did not contain a JSON object"
    else
        [ -n "$name" ] || die "--name is required"
        [ -n "$endpoint" ] || [ -n "$endpoint6" ] \
            || die "--endpoint or --endpoint6 is required (host:port, IPv6 in brackets)"
        [ -n "$public_key" ] || die "--public-key is required"
        node=$(jq -n --arg name "$name" --arg endpoint "$endpoint" --arg endpoint6 "$endpoint6" \
                     --arg key "$public_key" --arg psk "$psk" --arg protocol "$protocol" '
            {name: $name, public_key: $key}
            + (if $endpoint == "" then {} else {endpoint: $endpoint} end)
            + (if $endpoint6 == "" then {} else {endpoint6: $endpoint6} end)
            + (if $psk == "" then {} else {preshared_key: $psk} end)
            + (if $protocol == "" then {} else {protocol: $protocol} end)')
        local param
        for param in "${!obf[@]}"; do
            node=$(printf '%s' "$node" | jq --arg k "$(printf '%s' "$param" | tr '[:upper:]' '[:lower:]')" \
                                            --arg v "${obf[$param]}" \
                '. + {($k): (if ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end)}')
        done
    fi
    # Named alongside --json these win, for the same reason --protocol does: the
    # object may have come from a node whose addressing has since changed.
    if [ -n "$family" ]; then
        node=$(printf '%s' "$node" | jq --arg f "$family" '. + {family: $f}')
    fi
    # A generation named alongside --json wins: the object may have come from a node
    # that has since been moved.
    if [ -n "$protocol" ]; then
        node=$(printf '%s' "$node" | jq --arg p "$protocol" '. + {protocol: $p}')
    fi

    name=$(printf '%s' "$node" | jq -r '.name // ""')
    [ -n "$name" ] || die "the node object needs a name"

    local file uplink_subnet uplink_subnet6
    file=$(nodes_file)
    uplink_subnet=$(env_get "$ENV_FILE" CASCADE_UPLINK_SUBNET || echo 10.77.0.0/24)
    uplink_subnet6=$(env_get "$ENV_FILE" CASCADE_UPLINK_SUBNET6 || true)

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
    # The same for the IPv6 half, when the cascade has one. The two halves are
    # numbered in step — 10.77.0.4/32 beside fd00:77::4/128 — so that one uplink
    # reads as one link in `ip addr` and in a packet capture.
    if [ -n "$uplink_subnet6" ] && [ -z "$address6" ] \
        && ! printf '%s' "$node" | jq -e 'has("address6")' >/dev/null; then
        case ${uplink_subnet6%%/*} in
            *::)
                local n
                n=${address%%/*}
                n=${n##*.}
                case $n in
                    ''|*[!0-9]*) ;;
                    *) address6=$(printf '%s%x/128' "${uplink_subnet6%%/*}" "$n") ;;
                esac
                ;;
            *)
                warn "CASCADE_UPLINK_SUBNET6=${uplink_subnet6} cannot have host numbers appended to it; pass --address6 to put ${name} on the IPv6 bridge"
                ;;
        esac
    fi
    if [ -z "$priority" ] && ! printf '%s' "$node" | jq -e 'has("priority")' >/dev/null; then
        # `.[].priority // 100` would fall through to 100 on an empty list, so the
        # very first node has to be mapped explicitly.
        priority=$(jq '[.[] | .priority // 100] | (max // 0) + 10' "$file")
    fi

    jq --argjson node "$node" --arg address "$address" --arg address6 "$address6" \
       --arg priority "$priority" '
        . + [$node
             + (if $address == "" then {} else {address: $address} end)
             + (if $address6 == "" then {} else {address6: $address6} end)
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
        jq -n --arg name "$name" --arg address "$address" --arg address6 "$address6" \
            --arg key "$uplink_key" \
            '{ok: true, name: $name, address: $address,
              address6: (if $address6 == "" then null else $address6 end),
              uplink_public_key: (if $key == "" then null else $key end)}'
    else
        note "uplink address    ${address}"
        [ -z "$address6" ] || note "uplink address6   ${address6}"
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
        # The handshake is re-judged here rather than taken from the file: the file's
        # verdict was true when it was written, and a monitor that has stopped writing
        # leaves a true one standing indefinitely. Same rule and same numbers the node
        # container used, so the two only ever disagree about how long ago it was read.
        printf '%s' "$state" | jq -r '
            (now | floor) as $now
            | ((.handshake_timeout // 180) + (.failover_seconds // 30)) as $dead_after
            | (.bridge.subnet6 != null) as $v6
            | (["PRIO", "NAME", "IFACE", "STATUS", "HANDSHAKE"]
               + (if $v6 then ["VIA", "IPV6"] else [] end)
               + ["ENDPOINT"] | join("\t")),
            (.nodes | sort_by(.priority)[] |
                (if (.last_handshake // 0) > 0 then $now - .last_handshake else null end) as $age
                | (.healthy and $age != null and $age <= $dead_after) as $up
                | "\(.priority)\t\(.name)\t\(.iface)\t" +
                # `active` is not asked first: the route still points at a node that
                # has stopped handshaking, and calling that active is how an exit node
                # carrying nothing goes unnoticed. Same for one the cascade is still
                # holding as a failover target it cannot actually fail over to.
                (if ($up | not) and (.healthy or .active) then "stalled"
                 elif .active then "active"
                 elif $up then "standby"
                 elif (.peer_public_key == null) then "unpaired"
                 else "down" end) +
                "\t" +
                (if $age == null then "never"
                 elif $age < 120 then "\($age)s ago"
                 elif $age < 7200 then "\(($age / 60) | floor)m ago"
                 else "\(($age / 3600) | floor)h ago" end) +
                # Which family the tunnel is dialled over, and whether the exit node
                # reaches the IPv6 internet through it. Only shown on a cascade that
                # has an IPv6 half, so an IPv4-only node lists as it always did.
                (if $v6 then
                    "\tIPv\(.endpoint_family // 4)\t" +
                    (if .address6 == null then "-"
                     elif .healthy6 then "up"
                     else "down" end)
                 else "" end) +
                "\t\(.endpoint // "-")")'
    else
        jq -r '"PRIO\tNAME\tENDPOINT",
               (sort_by(.priority // 100)[] |
                   "\(.priority // 100)\t\(.name)\t\(.endpoint6 // .endpoint // "-")")' "$file"
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

    local json="" name="" endpoint="" endpoint6="" family="" address6="" protocol="" reload=true
    local -A obf=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            --endpoint|--endpoint4) endpoint=$2; shift 2 ;;
            --endpoint6) endpoint6=$2; shift 2 ;;
            --family|--endpoint-family) family=$2; shift 2 ;;
            --address6) address6=$2; shift 2 ;;
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
    [ -z "$family" ] || family=$(require_endpoint_family "$family")
    if [ "$(ip_family "$(endpoint_host "$endpoint")")" = 6 ] && [ -z "$endpoint6" ]; then
        endpoint6=$endpoint
        endpoint=""
    fi

    local patch='{}'
    if [ -n "$json" ]; then
        [ "$json" = "-" ] && json=$(cat)
        patch=$(printf '%s' "$json" | jq -e 'if type == "object" then . else error("not an object") end') \
            || die "--json did not contain a JSON object"
        [ -n "$name" ] || name=$(printf '%s' "$patch" | jq -r '.name // ""')
    fi
    [ -n "$name" ] || die "update-node needs a node name"

    # `none` takes an endpoint away rather than replacing it. An address that has
    # stopped working is not merely unused once a node has two: it is somewhere the
    # uplink is rebuilt onto every time the other one has a bad minute.
    local drop4=false drop6=false
    case $endpoint in none|off|no|'-') drop4=true; endpoint="" ;; esac
    case $endpoint6 in none|off|no|'-') drop6=true; endpoint6="" ;; esac
    [ -z "$endpoint" ] || patch=$(printf '%s' "$patch" | jq --arg v "$endpoint" '. + {endpoint: $v}')
    [ -z "$endpoint6" ] || patch=$(printf '%s' "$patch" | jq --arg v "$endpoint6" '. + {endpoint6: $v}')
    [ -z "$family" ] || patch=$(printf '%s' "$patch" | jq --arg v "$family" '. + {family: $v}')
    [ -z "$address6" ] || patch=$(printf '%s' "$patch" | jq --arg v "$address6" '. + {address6: $v}')
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

    # Refused rather than applied: a node with no address at all is one the cascade
    # can do nothing with but report as permanently down.
    if [ "$drop4" = true ] || [ "$drop6" = true ]; then
        # The patch is consulted before the stored node, so dropping one endpoint
        # while naming the other in the same command is allowed.
        jq -e --arg n "$name" --argjson patch "$patch" \
              --argjson d4 "$drop4" --argjson d6 "$drop6" '
            (.[] | select(.name == $n)) as $node
            | [(if $d4 then "" else ($patch.endpoint // $node.endpoint // "") end),
               (if $d6 then "" else ($patch.endpoint6 // $node.endpoint6 // "") end)]
            | any(.[]; . != "")' "$file" >/dev/null \
            || die "${name} would be left with no endpoint to dial"
    fi

    # The old generation's parameters are dropped rather than overwritten: a leftover
    # S3 would keep this uplink advertising 2.0 to an exit node that no longer does.
    local params_lower
    params_lower=$(printf '%s' "$AWG_OBF_PARAMS" | tr '[:upper:]' '[:lower:]')
    jq --arg n "$name" --argjson patch "$patch" --arg obf "$params_lower" \
       --argjson d4 "$drop4" --argjson d6 "$drop6" '
        ($obf | split(" ")) as $keys
        | map(if .name == $n
              then (if ($patch | has("protocol")) then delpaths([$keys[] | [.]]) else . end)
                   + ($patch | del(.name))
                   | (if $d4 then del(.endpoint) else . end)
                   | (if $d6 then del(.endpoint6) else . end)
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
            | "protocol  \(.protocol // "1.0")",
              "address   \(.address // "-")",
              (if .address6 then "address6  \(.address6)" else empty end),
              "endpoint  \(.endpoint // "-")",
              (if .endpoint6 then "endpoint6 \(.endpoint6)" else empty end),
              (if .family then "family    \(.family)" else empty end)' "$file" \
            | while IFS= read -r line; do note "$line"; done
    fi
}

# ---------------------------------------------------------------------------
# Direct routes and the fallback (entry node)
# ---------------------------------------------------------------------------

routes_file() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$ROUTES_FILE" ] || { printf '[]\n' > "$ROUTES_FILE"; chmod 600 "$ROUTES_FILE"; }
    printf '%s' "$ROUTES_FILE"
}

# The list as it stands, for reading. An absent file is an empty list rather than
# something to create: listing should not need write access to anything.
routes_json() {
    [ -f "$ROUTES_FILE" ] && jq '.' "$ROUTES_FILE" 2>/dev/null || printf '[]'
}

# The same masking the node container applies, so what is written here is what shows
# up in the routing table: a bare address is a single host, and an address inside a
# range is recorded as the range. Prints nothing for anything that is not an IPv4
# prefix.
normalize_prefix() {
    printf '%s' "$1" | jq -Rr '
        gsub("^\\s+|\\s+$"; "")
        | if (test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?$") | not) then ""
          else
            split("/") as $parts
            | (if ($parts | length) == 2 then ($parts[1] | tonumber) else 32 end) as $bits
            | ($parts[0] | split(".") | map(tonumber)) as $o
            | if $bits < 1 or $bits > 32 or ([$o[] | select(. > 255)] | length) > 0 then ""
              else
                ($o[0] * 16777216 + $o[1] * 65536 + $o[2] * 256 + $o[3]) as $addr
                | (pow(2; 32 - $bits) | floor) as $size
                | ($addr - ($addr % $size)) as $net
                | "\(($net / 16777216) | floor).\((($net % 16777216) / 65536) | floor).\((($net % 65536) / 256) | floor).\($net % 256)/\($bits)"
              end
          end'
}

cmd_add_route() {
    need_root add-route
    require_entry

    local note="" reload=true from_file="" args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --note) note=$2; shift 2 ;;
            --from-file) from_file=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            -*) die "unknown option for add-route: $1" ;;
            *) args+=("$1"); shift ;;
        esac
    done

    # A list of prefixes generated elsewhere — resolved from domain names, exported
    # from a router — is the usual way these arrive, so a whole file can be handed
    # over at once. Blank lines and comments are skipped.
    if [ -n "$from_file" ]; then
        [ -f "$from_file" ] || die "no such file: ${from_file}"
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%%#*}
            line=$(printf '%s' "$line" | tr -d '[:space:]')
            [ -n "$line" ] && args+=("$line")
        done < "$from_file"
    fi

    [ "${#args[@]}" -gt 0 ] || die "add-route needs at least one address or range"

    # Everything is validated before anything is written: half of a pasted list is
    # worse than none of it, since the half that landed is not obvious afterwards.
    local prefix normalized wanted='[]'
    for prefix in "${args[@]}"; do
        # A /0 is every destination, which is the cascade turned off rather than a
        # route past it — worth naming, because the alternative really does exist.
        case "$prefix" in
            */0) die "${prefix} would take every destination off the cascade; you may want: saucewg fallback direct" ;;
        esac
        normalized=$(normalize_prefix "$prefix")
        [ -n "$normalized" ] || die "not an IPv4 address or range: ${prefix}"
        wanted=$(printf '%s' "$wanted" | jq --arg c "$normalized" '. + [$c]')
    done

    local file before after added skipped
    file=$(routes_file)
    before=$(jq 'length' "$file")
    # Appended one at a time against the list as it grows, so a prefix that is already
    # there — or repeated in the input — is left alone rather than duplicated. An
    # existing entry keeps its own label: re-importing a group that has grown should
    # add what is new, not rewrite what is not.
    jq --argjson wanted "$wanted" --arg note "$note" '
        reduce $wanted[] as $cidr (.;
            if [.[] | (.cidr // .)] | index($cidr) then .
            else . + [{cidr: $cidr, enabled: true}
                      + (if $note == "" then {} else {note: $note} end)]
            end)' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    after=$(jq 'length' "$file")
    added=$((after - before))
    skipped=$(( ${#args[@]} - added ))

    log "added ${added} direct route(s)$([ "$skipped" -gt 0 ] && printf ', %s already listed' "$skipped")"
    if [ "$reload" = true ]; then
        request_reload
    else
        note "not applied yet; apply it with: saucewg reload"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --argjson added "$added" --argjson skipped "$skipped" \
        --slurpfile routes "$file" '{ok: true, added: $added, skipped: $skipped, routes: $routes[0]}'
}

cmd_remove_route() {
    need_root remove-route
    require_entry

    local note="" reload=true args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --note) note=$2; shift 2 ;;
            --no-reload) reload=false; shift ;;
            -*) die "unknown option for remove-route: $1" ;;
            *) args+=("$1"); shift ;;
        esac
    done
    [ "${#args[@]}" -gt 0 ] || [ -n "$note" ] \
        || die "remove-route needs an address, a range, or --note <group>"

    local file prefix normalized wanted='[]' before after
    file=$(routes_file)
    for prefix in ${args[@]+"${args[@]}"}; do
        normalized=$(normalize_prefix "$prefix")
        [ -n "$normalized" ] || die "not an IPv4 address or range: ${prefix}"
        wanted=$(printf '%s' "$wanted" | jq --arg c "$normalized" '. + [$c]')
    done

    before=$(jq 'length' "$file")
    jq --argjson wanted "$wanted" --arg note "$note" '
        map(select(
            ((.cidr // .) as $c | $wanted | index($c) | not)
            and (if $note == "" then true else (.note // "") != $note end)))' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    after=$(jq 'length' "$file")

    [ "$before" -ne "$after" ] || die "nothing matched; see: saucewg routes"
    log "removed $((before - after)) direct route(s)"

    if [ "$reload" = true ]; then
        request_reload
    else
        note "not applied yet; apply it with: saucewg reload"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --argjson removed "$((before - after))" \
        --slurpfile routes "$file" '{ok: true, removed: $removed, routes: $routes[0]}'
}

cmd_routes() {
    require_entry
    local routes state applied='[]' live=false
    routes=$(routes_json)

    # What the node container actually installed, which is the answer that matters:
    # an entry can be listed here and still not be in effect.
    state=$(compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null) || state=""
    if printf '%s' "$state" | jq -e 'has("direct")' >/dev/null 2>&1; then
        live=true
        applied=$(printf '%s' "$state" | jq -c '.direct.routes // []')
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        printf '%s' "$routes" | jq --argjson applied "$applied" --argjson live "$live" \
            '{routes: ., applied: $applied, live: $live}'
        return
    fi

    if [ "$(printf '%s' "$routes" | jq 'length')" -eq 0 ]; then
        note "no direct routes; every destination goes through the cascade"
        note "add one with: saucewg add-route 142.250.0.0/15 --note youtube"
        return
    fi

    # A hand-written list may hold bare strings, and `.enabled // true` would read an
    # explicit false as true, so each entry is normalised to an object first. The
    # prefix is shown the way the node container states it — a bare address is a /32
    # there — or nothing would ever match what it reports as applied.
    printf '%s' "$routes" | jq -r --argjson applied "$applied" --argjson live "$live" '
        "PREFIX\tSTATUS\tNOTE",
        (.[]
         | (if type == "string" then {cidr: .} else . end) as $r
         | (if ($r.cidr | test("/")) then $r.cidr else "\($r.cidr)/32" end) as $cidr
         | "\($cidr)\t" +
           (if $r.enabled == false then "off"
            elif ($live | not) then "unknown"
            elif ($applied | index($cidr)) then "direct"
            else "pending" end) +
           "\t\($r.note // "-")")' | column -t -s "$(printf '\t')"

    local error
    error=$(printf '%s' "$state" | jq -r '.direct.error // ""' 2>/dev/null) || error=""
    [ -z "$error" ] || warn "$error"
}

# What happens to client traffic while every exit node is down.
cmd_fallback() {
    require_entry

    local mode="${1:-}" restart=true
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-restart) restart=false; shift ;;
            *) die "unknown option for fallback: $1" ;;
        esac
    done

    if [ -z "$mode" ]; then
        local configured legacy state active=""
        configured=$(env_get "$ENV_FILE" CASCADE_FALLBACK || true)
        legacy=$(env_get "$ENV_FILE" CASCADE_KILLSWITCH || true)
        if [ -z "$configured" ]; then
            case "$legacy" in
                true|1|yes|on) configured=block ;;
                *) configured=direct ;;
            esac
        fi
        state=$(compose exec -T awg jq -r '"\(.fallback) \(.fallback_active)"' \
            /var/run/amneziawg/uplinks.json 2>/dev/null) || state=""
        [ -z "$state" ] || active=${state#* }

        if [ "$JSON_OUTPUT" = true ]; then
            jq -n --arg mode "$configured" --arg active "$active" \
                '{fallback: $mode, active: (if $active == "" then null else $active == "true" end)}'
        else
            note "fallback  ${configured}"
            case "$configured" in
                direct) note "          while every exit node is down, clients leave through this entry node" ;;
                *) note "          while every exit node is down, client traffic is dropped" ;;
            esac
            [ "$active" != "true" ] || warn "it is in use right now: no exit node is carrying traffic"
        fi
        return
    fi

    case "$mode" in
        direct|block) ;;
        *) die "fallback takes direct or block" ;;
    esac
    need_root "fallback ${mode}"

    env_set "$ENV_FILE" CASCADE_FALLBACK "$mode"
    # The legacy name would win on a node whose .env still carries it, and it can
    # only say "block".
    grep -q '^CASCADE_KILLSWITCH=' "$ENV_FILE" && env_set "$ENV_FILE" CASCADE_KILLSWITCH ""
    log "fallback set to ${mode}"

    if [ "$restart" = true ]; then
        step "Applying"
        # An environment change only reaches the process through a new container.
        compose up -d awg >&2
        note "connected clients reconnect on their own within a few seconds"
    else
        note "not applied yet; apply it with: saucewg restart"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --arg mode "$mode" '{ok: true, fallback: $mode}'
}

# ---------------------------------------------------------------------------
# The bridge
# ---------------------------------------------------------------------------
#
# The link between this entry node and its exit nodes. It carries IPv4 out of the
# box; this is what adds IPv6 to it, and what reports which family each tunnel is
# actually dialled over.
#
# Both ends have to agree. The entry node's CASCADE_UPLINK_SUBNET6 and each exit
# node's AWG_SUBNET6 name the same prefix, and until the exit node has one, its
# half of the bridge has no address and nothing comes back over it. So turning the
# bridge on here is announced as half the job, with the other half named.

cmd_bridge() {
    require_entry

    local action="${1:-}" subnet6="" family="" restart=true
    case "$action" in
        on|enable) subnet6=$CASCADE_UPLINK_SUBNET6_DEFAULT; shift ;;
        off|disable) subnet6=none; shift ;;
        4|6|auto) family=$action; shift ;;
        show|status) shift ;;
        */*|*:*) subnet6=$action; shift ;;
        ''|-*) ;;
        *) die "bridge takes on, off, auto, 4, 6, or an IPv6 prefix" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --subnet6) subnet6=$2; shift 2 ;;
            --family|--endpoint-family) family=$2; shift 2 ;;
            --no-restart) restart=false; shift ;;
            *) die "unknown option for bridge: $1" ;;
        esac
    done

    if [ -z "$subnet6" ] && [ -z "$family" ]; then
        local configured_subnet configured_subnet6 configured_family state
        configured_subnet=$(env_get "$ENV_FILE" CASCADE_UPLINK_SUBNET || echo 10.77.0.0/24)
        configured_subnet6=$(env_get "$ENV_FILE" CASCADE_UPLINK_SUBNET6 || true)
        configured_family=$(env_get "$ENV_FILE" CASCADE_ENDPOINT_FAMILY || true)
        [ -n "$configured_family" ] || configured_family=auto
        state=$(compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null) || state=""
        printf '%s' "$state" | jq -e 'has("nodes")' >/dev/null 2>&1 || state=""

        if [ "$JSON_OUTPUT" = true ]; then
            jq -n --arg subnet "$configured_subnet" --arg subnet6 "$configured_subnet6" \
                  --arg family "$configured_family" \
                  --argjson live "$(printf '%s' "${state:-null}")" '
                {subnet: $subnet,
                 subnet6: (if $subnet6 == "" then null else $subnet6 end),
                 family: $family,
                 nodes: (if $live == null then null else
                     [$live.nodes[] | {name, endpoint, endpoint4, endpoint6,
                                       endpoint_family, address, address6,
                                       healthy, healthy6, latency6_ms}] end)}'
            return
        fi

        note "subnet    ${configured_subnet}"
        if [ -n "$configured_subnet6" ]; then
            note "subnet6   ${configured_subnet6}"
        else
            note "subnet6   -         the bridge carries IPv4 only; turn it on with: saucewg bridge on"
        fi
        case "$configured_family" in
            4) note "family    4         exit nodes are dialled over IPv4" ;;
            6) note "family    6         exit nodes are dialled over IPv6" ;;
            *) note "family    auto      IPv6 where both ends have it, IPv4 otherwise" ;;
        esac
        if [ -n "$state" ]; then
            note ""
            printf '%s' "$state" | jq -r '
                "NAME\tVIA\tENDPOINT\tIPV6",
                (.nodes | sort_by(.priority)[] |
                    "\(.name)\tIPv\(.endpoint_family // 4)\t\(.endpoint // "-")\t" +
                    (if .address6 == null then "-"
                     elif .healthy6 then "\(.address6) up"
                     else "\(.address6) down" end))' \
                | column -t -s "$(printf '\t')"
        fi
        return
    fi

    need_root bridge

    if [ -n "$family" ]; then
        family=$(require_endpoint_family "$family")
        env_set "$ENV_FILE" CASCADE_ENDPOINT_FAMILY "$family"
        case "$family" in
            4|6) log "exit nodes will be dialled over IPv${family}" ;;
            *) log "exit nodes will be dialled over IPv6 where both ends have it, IPv4 otherwise" ;;
        esac
    fi

    if [ -n "$subnet6" ]; then
        case $subnet6 in
            none|off|no|false) subnet6="" ;;
            auto|yes|on|true) subnet6=$CASCADE_UPLINK_SUBNET6_DEFAULT ;;
            *:*/*) ;;
            *) die "--subnet6 takes an IPv6 prefix like ${CASCADE_UPLINK_SUBNET6_DEFAULT}, or none" ;;
        esac
        env_set "$ENV_FILE" CASCADE_UPLINK_SUBNET6 "$subnet6"
        if [ -n "$subnet6" ]; then
            log "the bridge now carries IPv6 on ${subnet6}"
            note ""
            note "Each exit node needs the same prefix before anything comes back over it:"
            note "  saucewg install-node --subnet6 ${subnet6} --reinstall   # on each exit node"
            note "Then give each uplink an address on it:"
            note "  saucewg update-node <name> --address6 ${subnet6%%/*}<n>"
            note ""
            note "Clients stay on IPv4: this is the link between the servers, not the"
            note "tunnel a client builds. Nothing a client sends can reach it."
        else
            log "the bridge carries IPv4 only again"
        fi
    fi

    if [ "$restart" = true ]; then
        step "Applying"
        # An environment change only reaches the process through a new container.
        compose up -d awg >&2
        note "connected clients reconnect on their own within a few seconds"
    else
        note "not applied yet; apply it with: saucewg restart"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --arg subnet6 "$subnet6" --arg family "$family" \
        '{ok: true,
          subnet6: (if $subnet6 == "" then null else $subnet6 end),
          family: (if $family == "" then null else $family end)}'
}

# ---------------------------------------------------------------------------
# Dial-in
# ---------------------------------------------------------------------------
#
# Normally this node dials its exit nodes. Filtering is not always symmetrical,
# though: a path that drops what this node sends can still carry what the exit node
# sends, and a tunnel established from the far end carries traffic both ways like
# any other. Turning this on gives each uplink a fixed port and prints what to run
# on each exit node to point it here.
#
# It is worth having even where both directions work, because an uplink whose port
# the kernel picks gets a new one on every restart, and an exit node goes on
# sending to the port it last heard from.
cmd_dial_in() {
    require_entry

    local action="${1:-}" base="" restart=true
    case "$action" in
        on|enable) base=$CASCADE_UPLINK_PORT_BASE_DEFAULT; shift ;;
        off|disable) base=none; shift ;;
        show|status) shift ;;
        [0-9]*) base=$action; shift ;;
        ''|-*) ;;
        *) die "dial-in takes on, off, or a base port number" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --port-base|--base) base=$2; shift 2 ;;
            --no-restart) restart=false; shift ;;
            *) die "unknown option for dial-in: $1" ;;
        esac
    done

    if [ -z "$base" ]; then
        local configured host state
        configured=$(env_get "$ENV_FILE" CASCADE_UPLINK_PORT_BASE || true)
        host=$(env_get "$ENV_FILE" AWG_ENDPOINT_HOST || true)
        [ -n "$host" ] || host=$(public_ip || echo "<this node>")
        state=$(compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null) || state=""
        printf '%s' "$state" | jq -e 'has("nodes")' >/dev/null 2>&1 || state=""

        if [ "$JSON_OUTPUT" = true ]; then
            jq -n --arg base "$configured" --arg host "$host" \
                  --argjson live "$(printf '%s' "${state:-null}")" '
                {port_base: (if $base == "" then null else ($base | tonumber) end),
                 host: $host,
                 nodes: (if $live == null then null else
                     [$live.nodes[] | {name, listen_port,
                        dial: (if .listen_port == null then null
                               else "\($host):\(.listen_port)" end)}] end)}'
            return
        fi

        if [ -z "$configured" ]; then
            note "port base -         the kernel picks each uplink's port"
            note ""
            note "Exit nodes cannot be pointed at a port that changes on every restart."
            note "Give the uplinks fixed ports with: saucewg dial-in on"
            return
        fi
        local from to
        read -r from to <<<"$(uplink_port_range "$configured")"
        note "port base ${configured}       uplinks listen on ${from}-${to}/udp"
        note "host      ${host}"
        if [ -n "$state" ]; then
            note ""
            printf '%s' "$state" | jq -r --arg host "$host" '
                "NAME\tPORT\tRUN ON THE EXIT NODE",
                (.nodes | sort_by(.priority)[] |
                    "\(.name)\t\(.listen_port // "-")\t" +
                    (if .listen_port == null then "-"
                     else "saucewg node-pair --peer-key \(.public_key) --peer-endpoint \($host):\(.listen_port)"
                     end))' \
                | column -t -s "$(printf '\t')"
        fi
        return
    fi

    need_root dial-in

    case $base in
        none|off|no|false) base="" ;;
        *) base=$(require_port_base "$base") ;;
    esac
    env_set "$ENV_FILE" CASCADE_UPLINK_PORT_BASE "$base"

    if [ -n "$base" ]; then
        local from to
        read -r from to <<<"$(uplink_port_range "$base")"
        open_node_port "$from" "$to"
        log "the uplinks now listen on ${from}-${to}/udp"
        note ""
        note "Each exit node has to be told where to dial before it will:"
        note "  saucewg dial-in            # here, for the command to run on each"
        note ""
        note "Nothing changes for an exit node that is not told. This node goes on"
        note "dialling as it always has, and a tunnel the far end builds is the same"
        note "tunnel either way."
    else
        log "the uplinks go back to whatever port the kernel picks"
        note "an exit node still configured to dial in will stop finding this node"
    fi

    if [ "$restart" = true ]; then
        step "Applying"
        compose up -d awg >&2
        note "connected clients reconnect on their own within a few seconds"
    else
        note "not applied yet; apply it with: saucewg restart"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --arg base "$base" \
        '{ok: true, port_base: (if $base == "" then null else ($base | tonumber) end)}'
}

# ---------------------------------------------------------------------------
# Bypass
# ---------------------------------------------------------------------------
#
# Destinations that are blocked at the point where a TCP connection is
# established: the SYN to their IPv4 is dropped, so nothing ever connects, while
# ICMP and every already-established flow pass. A route cannot fix that, so
# `add-route` cannot either — the entry node has to open the outbound half itself,
# over the destination's IPv6 or by dialling its IPv4 until a handshake lands.
#
# The built-in `telegram` group is what most installations need and is on by
# default; this list is for anything else, or for correcting a group.

bypass_list_file() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$BYPASS_LIST_FILE" ] || { printf '[]\n' > "$BYPASS_LIST_FILE"; chmod 600 "$BYPASS_LIST_FILE"; }
    printf '%s' "$BYPASS_LIST_FILE"
}

bypass_list_json() {
    [ -f "$BYPASS_LIST_FILE" ] && jq '.' "$BYPASS_LIST_FILE" 2>/dev/null || printf '[]'
}

# What the node container installed, which is the answer that matters: a
# destination can be listed here and not be redirected, either because the mode
# says not to or because an exit node is carrying the traffic.
bypass_state() {
    compose exec -T awg cat /var/run/amneziawg/uplinks.json 2>/dev/null || true
}

bypass_mode_configured() {
    local mode
    mode=$(env_get "$ENV_FILE" BYPASS_MODE || true)
    printf '%s' "${mode:-auto}"
}

cmd_bypass() {
    require_entry
    local action="${1:-}"
    case "$action" in
        add|remove) shift; bypass_edit "$action" "$@"; return ;;
        auto|always|off) shift; bypass_set_mode "$action" "$@"; return ;;
        "") ;;
        -*) die "unknown option for bypass: $action" ;;
        *) die "bypass takes auto, always, off, add or remove" ;;
    esac

    local mode state list applied='[]' active=null relay=null error="" live=false
    mode=$(bypass_mode_configured)
    list=$(bypass_list_json)
    state=$(bypass_state)
    if printf '%s' "$state" | jq -e 'has("bypass")' >/dev/null 2>&1; then
        live=true
        applied=$(printf '%s' "$state" | jq -c '.bypass.routes // []')
        active=$(printf '%s' "$state" | jq -c '.bypass.active')
        relay=$(printf '%s' "$state" | jq -c '.bypass.relay')
        error=$(printf '%s' "$state" | jq -r '.bypass.error // ""')
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        printf '%s' "$list" | jq --arg mode "$mode" --argjson applied "$applied" \
            --argjson active "$active" --argjson relay "$relay" --arg error "$error" \
            --argjson live "$live" '{
                mode: $mode, list: ., applied: $applied, active: $active,
                relay: $relay, live: $live,
                error: (if $error == "" then null else $error end)
            }'
        return
    fi

    note "bypass    ${mode}"
    case "$mode" in
        auto) note "          engages only while every exit node is down and clients leave through here" ;;
        always) note "          engaged whether or not an exit node is carrying client traffic" ;;
        off) note "          nothing is reopened; blocked destinations stay blocked" ;;
    esac
    if [ "$live" = false ]; then
        warn "the node container did not answer, so nothing below is confirmed"
    elif [ "$active" = true ]; then
        local count
        count=$(printf '%s' "$state" | jq -r '.bypass.applied')
        note "          in force right now for ${count} destination(s)"
        printf '%s' "$relay" | jq -e '. != null' >/dev/null 2>&1 && printf '%s' "$relay" | jq -r '
            "          \(.accepted) connection(s): \(.via_v6) over IPv6, \(.via_retry) by retrying IPv4 in \(.attempts) handshake(s), \(.failed) unreachable"
            + (if (.cooled // 0) > 0 then
                "\n          \(.cooled) went to a destination already known not to answer, and cost one handshake each"
              else "" end)' >&2
    elif [ "$mode" != off ]; then
        note "          not in force: an exit node is carrying client traffic"
    fi

    if [ "$(printf '%s' "$list" | jq 'length')" -gt 0 ]; then
        printf '\n' >&2
        printf '%s' "$list" | jq -r --argjson applied "$applied" '
            "PREFIX\tVIA\tSTATUS\tNOTE",
            (.[]
             | (if type == "string" then {cidr: .} else . end) as $r
             | (if ($r.cidr | test("/")) then $r.cidr else "\($r.cidr)/32" end) as $cidr
             | ($applied | map(select(.cidr == $cidr)) | first) as $live
             | "\($cidr)\t\((($live.v6 // $r.v6 // $r.ipv6) // "retry"))\t" +
               (if $r.enabled == false then "off"
                elif $live then "reopened"
                else "pending" end) +
               "\t\($r.note // "-")")' | column -t -s "$(printf '\t')" >&2
    fi
    [ -z "$error" ] || warn "$error"
}

bypass_set_mode() {
    local mode=$1 restart=true
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-restart) restart=false; shift ;;
            *) die "unknown option for bypass ${mode}: $1" ;;
        esac
    done
    need_root "bypass ${mode}"

    env_set "$ENV_FILE" BYPASS_MODE "$mode"
    log "bypass set to ${mode}"

    if [ "$restart" = true ]; then
        step "Applying"
        # The mode is read from the environment, which only a new container sees.
        compose up -d awg >&2
        note "connected clients reconnect on their own within a few seconds"
    else
        note "not applied yet; apply it with: saucewg restart"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --arg mode "$mode" '{ok: true, bypass: $mode}'
}

bypass_edit() {
    local action=$1 note_label="" v6="" reload=true disable=false args=()
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --note) note_label=$2; shift 2 ;;
            --v6) v6=$2; shift 2 ;;
            # A built-in group is a list this script ships, so switching one of its
            # entries off has to be recorded here rather than by editing the group.
            --disable) disable=true; shift ;;
            --no-reload) reload=false; shift ;;
            -*) die "unknown option for bypass ${action}: $1" ;;
            *) args+=("$1"); shift ;;
        esac
    done

    need_root "bypass ${action}"
    [ "${#args[@]}" -gt 0 ] || [ -n "$note_label" ] \
        || die "bypass ${action} needs an address or range$([ "$action" = remove ] && printf ', or --note GROUP')"

    if [ -n "$v6" ]; then
        [ "$action" = add ] || die "--v6 only applies to: bypass add"
        [ "${#args[@]}" -eq 1 ] || die "--v6 names one destination's counterpart, so pass one prefix"
        printf '%s' "$v6" | grep -q ':' || die "not an IPv6 address: ${v6}"
    fi

    local prefix normalized wanted='[]'
    for prefix in ${args[@]+"${args[@]}"}; do
        case "$prefix" in
            */0) die "${prefix} would send every destination through the relay" ;;
        esac
        normalized=$(normalize_prefix "$prefix")
        [ -n "$normalized" ] || die "not an IPv4 address or range: ${prefix}"
        wanted=$(printf '%s' "$wanted" | jq --arg c "$normalized" '. + [$c]')
    done

    local file before after
    file=$(bypass_list_file)
    before=$(jq 'length' "$file")

    if [ "$action" = add ]; then
        # Re-stated rather than skipped when it is already there: unlike a direct
        # route, an entry here carries how to reach the destination, and correcting
        # that is the main reason to add one twice.
        jq --argjson wanted "$wanted" --arg note "$note_label" --arg v6 "$v6" \
           --argjson enabled "$([ "$disable" = true ] && echo false || echo true)" '
            reduce $wanted[] as $cidr (.;
                map(select((.cidr // .) != $cidr))
                + [{cidr: $cidr, enabled: $enabled}
                   + (if $v6 == "" then {} else {v6: $v6} end)
                   + (if $note == "" then {} else {note: $note} end)])' "$file" > "${file}.tmp"
    else
        jq --argjson wanted "$wanted" --arg note "$note_label" '
            map(select(
                ((.cidr // .) as $c | $wanted | index($c) | not)
                and (if $note == "" then true else (.note // "") != $note end)))' "$file" > "${file}.tmp"
    fi
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
    after=$(jq 'length' "$file")

    if [ "$action" = add ]; then
        if [ "$disable" = true ]; then
            log "listed ${#args[@]} destination(s) as not to be reopened"
        else
            log "reopening ${#args[@]} destination(s) through this entry node"
        fi
    else
        [ "$before" -ne "$after" ] || die "nothing matched; see: saucewg bypass"
        log "removed $((before - after)) bypass entr$([ $((before - after)) -eq 1 ] && printf 'y' || printf 'ies')"
    fi

    # The node container watches this file, so an edit needs no restart — only the
    # nudge that makes it look now rather than on its next tick.
    if [ "$reload" = true ]; then
        request_reload
    else
        note "not applied yet; apply it with: saucewg reload"
    fi

    [ "$JSON_OUTPUT" = false ] || jq -n --slurpfile list "$file" \
        --argjson changed "$([ "$action" = add ] && printf '%s' "${#args[@]}" || printf '%s' "$((before - after))")" \
        '{ok: true, changed: $changed, list: $list[0]}'
}

# ---------------------------------------------------------------------------
# Torrents
# ---------------------------------------------------------------------------
#
# A swarm sees the address of whichever server carries a client's traffic out, and
# a datacentre answers a copyright notice by suspending that server rather than by
# asking who was behind it. One client seeding for an evening costs the node and
# every other client on it — which is why this is a switch on the node rather than
# a policy for an operator to enforce by asking.
#
# It applies on an exit node as well as an entry node: what arrives over an uplink
# is still in the clear on the far side, and the exit node is the address that ends
# up in the notice.

torrent_switch_read() {
    [ -f "$TORRENT_SWITCH_FILE" ] \
        && jq -c '{enabled: (.enabled != false), mode: (.mode // "on")}' "$TORRENT_SWITCH_FILE" 2>/dev/null \
        || printf '{"enabled":false,"mode":"on"}'
}

torrent_switch_write() {
    local enabled=$1 mode=$2
    mkdir -p "$CONFIG_DIR"
    jq -n --argjson enabled "$enabled" --arg mode "$mode" \
        '{enabled: $enabled, mode: $mode}' > "${TORRENT_SWITCH_FILE}.tmp"
    mv "${TORRENT_SWITCH_FILE}.tmp" "$TORRENT_SWITCH_FILE"
    chmod 600 "$TORRENT_SWITCH_FILE"
}

# What the node container installed, which is the answer that matters: the file
# only records what was asked for.
torrent_state() {
    compose exec -T awg cat /var/run/amneziawg/torrents.json 2>/dev/null || true
}

cmd_torrents() {
    require_installed
    local action="${1:-}"
    case "$action" in
        on|strict|off) shift; torrent_set_mode "$action" "$@"; return ;;
        "") ;;
        -*) die "unknown option for torrents: $action" ;;
        *) die "torrents takes on, strict or off" ;;
    esac

    local configured pinned state live=false
    configured=$(torrent_switch_read)
    pinned=$(env_get "$ENV_FILE" TORRENT_BLOCK || true)
    state=$(torrent_state)
    printf '%s' "$state" | jq -e 'has("mode")' >/dev/null 2>&1 && live=true

    if [ "$JSON_OUTPUT" = true ]; then
        # A container that did not answer leaves `state` empty, and jq passes empty
        # input through as no output at all rather than as a failure — so the null
        # has to be substituted here rather than fallen back to.
        [ "$live" = true ] || state=null
        printf '%s' "$configured" | jq --argjson live "$live" --arg pinned "$pinned" \
            --argjson state "$(printf '%s' "$state" | jq -c '.')" '
            . + {live: $live, node: $state,
                 pinned: (if $pinned == "" then null else $pinned end)}'
        return
    fi

    local want
    want=$(printf '%s' "$configured" | jq -r 'if .enabled then .mode else "off" end')
    [ -z "$pinned" ] || want=$pinned

    note "torrents  ${want}"
    case "$want" in
        off)    note "          BitTorrent is forwarded like anything else" ;;
        on)     note "          peer discovery and the peer wire are blocked, and caught peers blacklisted" ;;
        strict) note "          the same, plus outbound TCP and UDP only to the ports a service answers on" ;;
    esac
    [ -z "$pinned" ] \
        || warn "TORRENT_BLOCK=${pinned} is set in .env, so the panel's switch is ignored"

    if [ "$live" = false ]; then
        warn "the node container did not answer, so nothing below is confirmed"
        return
    fi

    printf '%s' "$state" | jq -r '
        "          " + (if .active then "in force on \(.iface) with \(.rules) rule(s)"
                        else "not installed on the node right now" end)
        + (if (.peers // 0) > 0 then "\n          \(.peers) peer address(es) blacklisted" else "" end)
        + (if (.blocked.total // 0) > 0 then "\n          \(.blocked.total) packet(s) dropped" else "" end)
        # `// true` would read a kernel that has no string match as one that does:
        # in jq, false is empty and the alternative wins. The node reports the same
        # thing in .error, so this only speaks when something worse has crowded it out.
        + (if .capabilities.string == false and ((.error // "") | test("string") | not)
           then "\n          this kernel has no string match, so only the port rules are in force"
           else "" end)' >&2

    local caught
    caught=$(printf '%s' "$state" | jq -r '.clients | length')
    if [ "${caught:-0}" -gt 0 ]; then
        printf '\n' >&2
        printf '%s' "$state" | jq -r '
            "CLIENT\tPACKETS\tEXPIRES IN",
            (.clients[] | "\(.address)\t\(.packets)\t\(.expires_in)s")' \
            | column -t -s "$(printf '\t')" >&2
    fi

    printf '%s' "$state" | jq -r '.error // ""' | grep . | while read -r line; do
        warn "$line"
    done
}

torrent_set_mode() {
    local mode=$1
    shift
    [ $# -eq 0 ] || die "unknown option for torrents ${mode}: $1"
    need_root "torrents ${mode}"

    local pinned
    pinned=$(env_get "$ENV_FILE" TORRENT_BLOCK || true)
    [ -z "$pinned" ] \
        || die "TORRENT_BLOCK=${pinned} is set in .env and overrides this. Clear it first."

    # The mode is kept even while the guard is off, so turning it back on returns to
    # the mode that was chosen rather than to the default.
    local keep
    keep=$(torrent_switch_read | jq -r .mode)
    case "$mode" in
        off) torrent_switch_write false "$keep" ;;
        *)   torrent_switch_write true "$mode" ;;
    esac
    log "torrent blocking set to ${mode}"
    [ "$mode" != strict ] \
        || note "strict refuses outbound ports nothing answers on, which also breaks a VPN run inside the tunnel"

    # No reload to request and nothing to batch: this is one switch rather than a
    # list, and the node container watches the file on every role. It picks the
    # change up on its next second and applies it without touching a tunnel.
    note "the node applies it within a second"

    [ "$JSON_OUTPUT" = false ] || jq -n --arg mode "$mode" '{ok: true, torrents: $mode}'
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
    local newer
    # Hand the update over to the newer script rather than pulling its images with this
    # one's idea of what belongs in the compose file.
    if newer=$(cli_self_update); then
        log "saucewg ${SAUCEWG_VERSION} → ${newer}; running the rest of the update with it"
        SAUCEWG_SELF_UPDATED=1 exec "$CLI_PATH" ${SAUCEWG_ARGV[@]+"${SAUCEWG_ARGV[@]}"}
    fi
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
        grep -q '^ROUTES_REGISTRY_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" ROUTES_REGISTRY_FILE /etc/saucewg/host/direct-routes.json
        grep -q '^BYPASS_REGISTRY_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" BYPASS_REGISTRY_FILE /etc/saucewg/host/bypass.json
        grep -q '^CASCADE_DIRECT_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" CASCADE_DIRECT_FILE /etc/amnezia/host/direct-routes.json
        grep -q '^BYPASS_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" BYPASS_FILE /etc/amnezia/host/bypass.json
        grep -q '^BYPASS_GROUPS=' "$ENV_FILE" \
            || env_set "$ENV_FILE" BYPASS_GROUPS telegram
        # Written down rather than left to the container's own default, so the file
        # says what the relay will actually do on a network that needs it tuned.
        grep -q '^BYPASS_ATTEMPTS=' "$ENV_FILE" \
            || env_set "$ENV_FILE" BYPASS_ATTEMPTS 96
        grep -q '^BYPASS_PARALLEL=' "$ENV_FILE" \
            || env_set "$ENV_FILE" BYPASS_PARALLEL 6

        # Telegram is reachable from most Russian hosting segments only by not using
        # the IPv4 a client asks for, and an entry node carrying traffic itself hits
        # that. Reopening it is on by default because the alternative is that the
        # app does not connect at all — but it is written down and announced, since
        # it changes how those flows leave the server.
        if ! grep -q '^BYPASS_MODE=' "$ENV_FILE"; then
            env_set "$ENV_FILE" BYPASS_MODE auto
            note "destinations whose IPv4 handshake is being dropped are now reopened while clients leave through this node"
            note "  see what that covers with: saucewg bypass"
        fi

        # Failing over is not repairing: without this a dead exit node stays dead
        # until an operator notices, which is exactly what nothing tells them about.
        # It only ever acts on a node the panel holds a key for, and it stops rather
        # than hammering a server that does not answer at all.
        if ! grep -q '^NODE_RECOVERY_ENABLED=' "$ENV_FILE"; then
            env_set "$ENV_FILE" NODE_RECOVERY_ENABLED true
            env_set "$ENV_FILE" NODE_RECOVERY_GRACE_SECONDS 300
            env_set "$ENV_FILE" NODE_RECOVERY_INTERVAL_SECONDS 60
            env_set "$ENV_FILE" NODE_RECOVERY_MAX_ATTEMPTS 6
            note "the panel now tries to restart an exit node that has failed, instead of only routing around it"
            note "  run it yourself with: saucewg recover"
        fi

        # Before this release the only choice was to block client traffic while every
        # exit node was down. Carrying it through the entry node instead keeps clients
        # online, so it becomes the default here — but it is written into the .env and
        # announced rather than assumed, because it changes which address a client's
        # traffic appears from during an outage.
        if ! grep -q '^CASCADE_FALLBACK=' "$ENV_FILE"; then
            env_set "$ENV_FILE" CASCADE_FALLBACK direct
            note "while every exit node is down, clients now leave through this entry node instead of being cut off"
            note "  keep the old behaviour with: saucewg fallback block"
        fi

        grep -q '^TORRENT_REGISTRY_FILE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" TORRENT_REGISTRY_FILE /etc/saucewg/host/torrent-block.json

        # The IPv6 half of the link to the exit nodes, and which endpoint to dial
        # them over. Both arrive switched off rather than on: an update must leave a
        # running cascade doing exactly what it did, and an IPv6 bridge needs the
        # exit nodes rebuilt with a matching AWG_SUBNET6 before it carries anything.
        # `saucewg bridge on` is the one step that turns it on at both ends.
        grep -q '^CASCADE_UPLINK_SUBNET6=' "$ENV_FILE" \
            || env_set "$ENV_FILE" CASCADE_UPLINK_SUBNET6 ""
        grep -q '^CASCADE_ENDPOINT_FAMILY=' "$ENV_FILE" \
            || env_set "$ENV_FILE" CASCADE_ENDPOINT_FAMILY auto
        # Empty, so an uplink goes on using whatever port the kernel picks and no
        # exit node starts dialling inwards because of an update.
        grep -q '^CASCADE_UPLINK_PORT_BASE=' "$ENV_FILE" \
            || env_set "$ENV_FILE" CASCADE_UPLINK_PORT_BASE ""
        grep -q '^CASCADE_PROBE_TARGET6=' "$ENV_FILE" \
            || env_set "$ENV_FILE" CASCADE_PROBE_TARGET6 2606:4700:4700::1111
    else
        write_exit_compose
        env_set "$ENV_FILE" IMAGE_AWG "$(image_ref awg)"
        env_set "$ENV_FILE" SAUCEWG_TAG "$IMAGE_TAG"
        # The exit compose file gained a bind mount for this directory, and docker
        # would otherwise create it root-owned on first start.
        mkdir -p "$CONFIG_DIR"

        grep -q '^AWG_SUBNET6=' "$ENV_FILE" || env_set "$ENV_FILE" AWG_SUBNET6 ""
    fi

    grep -q '^TORRENT_BLOCK_FILE=' "$ENV_FILE" \
        || env_set "$ENV_FILE" TORRENT_BLOCK_FILE /etc/amnezia/host/torrent-block.json
    grep -q '^TORRENT_BLOCK=' "$ENV_FILE" || env_set "$ENV_FILE" TORRENT_BLOCK ""

    # One client seeding is a copyright notice and a suspended server, and the
    # server it names is whichever one carried the traffic out — so this arrives on
    # by default rather than as something to discover after losing a node. It is the
    # standard mode, which blocks BitTorrent and nothing else; `strict` is a wider
    # trade and stays opt-in.
    if [ ! -f "$TORRENT_SWITCH_FILE" ]; then
        mkdir -p "$CONFIG_DIR"
        torrent_switch_write true on
        note "BitTorrent is now blocked in the traffic this node forwards"
        note "  see what it catches, or turn it off, with: saucewg torrents"
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

# Puts a failed exit node back, rather than only routing around it.
#
# The cascade's own failover moves clients off a dead uplink within about thirty
# seconds and leaves it dead. Bringing the server back needs a shell on it, and the
# panel is the only part of the installation that has one: it holds an SSH key for
# every node it installed. So this runs there — probe, restart, and re-pair if the
# two ends have stopped agreeing on keys.
#
# The same escalation runs on a timer inside the panel; this is it on demand, for an
# operator who would rather not wait out the grace period.
cmd_recover() {
    need_root recover
    require_entry

    # A node that does not come back is an answer rather than a CLI failure, so the
    # panel's exit status is passed through and its report is printed either way.
    local json status=0
    json=$(compose exec -T panel python -m app.cli recover "$@") || status=$?
    printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 \
        || die "the panel did not answer; is it running? (saucewg logs panel)"

    if [ "$JSON_OUTPUT" = true ]; then
        printf '%s' "$json" | jq .
    else
        printf '%s' "$json" | jq -r '
            if length == 0 then "every exit node is healthy"
            else "NAME\tTRIED\tRESULT\tDETAIL",
                 (.[] | "\(.name)\t\(.last_action // "-")\t" +
                  (if .healthy then "recovered"
                   elif .blocked == "unreachable" then "unreachable — check the server exists"
                   elif .blocked == "exhausted" then "gave up"
                   else "still down" end) +
                  "\t\(.last_error // "-")")
            end' | column -t -s "$(printf '\t')"
    fi
    return $status
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
                             (both take --protocol ${AWG_PROTOCOL_LATEST} and --signature quic;
                             --uplink-subnet6 auto / --subnet6 auto adds IPv6 to the bridge)
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
    recover [NAME…]          Put failed exit nodes back: restart, then re-pair
                             (defaults to every unhealthy node; needs the panel)
    admin-password           Reset the panel admin password

  Routing (entry node)
    routes                   Destinations that bypass the cascade
    add-route CIDR…          Send an address or range through this entry node
                             (--note GROUP labels them, --from-file PATH reads a list)
    remove-route CIDR…       Put them back on the cascade (--note GROUP removes a group)
    fallback [direct|block]  What happens while every exit node is down

  The bridge to the exit nodes (entry node)
    bridge                   Which families the link carries, and how each node is dialled
    bridge on | off          Carry IPv6 inside the tunnels as well as IPv4
                             (or name a prefix: bridge fd00:77::/64)
    bridge auto | 4 | 6      Which endpoint to dial an exit node over when it has both
    dial-in                  Each uplink's fixed port, and what to run on each exit node
    dial-in on | off         Let an exit node dial this node instead of being dialled
                             (or name a base port: dial-in 51820)

  Blocked destinations (entry node)
    bypass                   Destinations this node reopens, and whether it is doing so
    bypass auto|always|off   auto reopens them only while clients leave through here
    bypass add CIDR…         Reopen a destination whose IPv4 handshake is dropped
                             (--v6 ADDR names its IPv6, --disable turns a built-in off)
    bypass remove CIDR…      Stop reopening it (--note GROUP removes a group)

  Torrents (any node)
    torrents                 Whether BitTorrent is blocked here, and what was caught
    torrents on              Block peer discovery, the peer wire and caught peers
    torrents strict          The same, plus outbound only to ports a service answers on
    torrents off             Forward it like anything else

  Exit node
    node-info                Print this node's pairing object
    node-pair --peer-key K   Install the entry node's uplink key here
                             (--peer-endpoint HOST:PORT dials the entry node from
                             here instead of waiting to be dialled)

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
    bash <(curl -fsSL ${RAW_BASE}/saucewg.sh) install-node --subnet6 auto --json
                                                           # exit node with IPv6

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
    ROUTES_FILE="${CONFIG_DIR}/direct-routes.json"
    BYPASS_LIST_FILE="${CONFIG_DIR}/bypass.json"
    TORRENT_SWITCH_FILE="${CONFIG_DIR}/torrent-block.json"

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
        recover)          cmd_recover "$@" ;;
        admin-password)   cmd_admin_password "$@" ;;
        routes|list-routes) cmd_routes "$@" ;;
        add-route)        cmd_add_route "$@" ;;
        remove-route)     cmd_remove_route "$@" ;;
        fallback)         cmd_fallback "$@" ;;
        bridge)           cmd_bridge "$@" ;;
        dial-in|dialin)   cmd_dial_in "$@" ;;
        bypass)           cmd_bypass "$@" ;;
        torrents|torrent) cmd_torrents "$@" ;;
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

# Kept whole because `update` may replace this script and re-run the same command with it.
SAUCEWG_ARGV=("$@")
main "$@"
