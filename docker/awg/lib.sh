#!/usr/bin/env bash
# Shared helpers for the AmneziaWG node entrypoint.

log() { printf '[awg] %s\n' "$*" >&2; }
die() { printf '[awg] FATAL: %s\n' "$*" >&2; exit 1; }

# Uniformly distributed integer in [$1, $2].
rand_range() {
    local min=$1 max=$2 span raw
    span=$((max - min + 1))
    raw=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
    echo $((min + raw % span))
}

awg_genkey() { awg genkey; }
awg_pubkey() { printf '%s' "$1" | awg pubkey; }

first_host() {
    # 10.8.0.0/24 -> 10.8.0.1/24
    local cidr=$1 net prefix
    net=${cidr%%/*}
    prefix=${cidr##*/}
    echo "${net%.*}.1/${prefix}"
}

# ---------------------------------------------------------------------------
# Address families
# ---------------------------------------------------------------------------
#
# The cascade speaks both: an uplink may be dialled over either family, and the
# bridge between two nodes carries both. Which family a string belongs to is
# decided by its shape rather than by which variable it arrived in, so one
# endpoint column in the exit node list takes either.

# 4, 6, or empty for a hostname — a name is not resolved here, because the
# family it answers with is not ours to assume.
ip_family() {
    local value=${1:-}
    case $value in
        '') return 0 ;;
        *:*) printf '6'; return 0 ;;
        *[!0-9.]*) return 0 ;;
        *.*.*.*) printf '4' ;;
    esac
}

# The host half of an endpoint, with an IPv6 literal's brackets removed.
#
# A bare IPv6 address is all colons and a bracketed one is unambiguous, so the
# only case that needs care is `host:port`: cutting at the last colon would turn
# 2001:db8::1 into 2001:db8:.
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

# The port, or empty when the endpoint carries none.
endpoint_port() {
    local value=${1:-}
    case $value in
        \[*\]:*) printf '%s' "${value##*]:}" ;;
        *:*:*) ;;
        *:*) printf '%s' "${value##*:}" ;;
    esac
}

endpoint_family() {
    ip_family "$(endpoint_host "${1:-}")"
}

# Puts the brackets back. amneziawg-tools reads `Endpoint = [2001:db8::1]:51820`
# and nothing else for an IPv6 peer, so every endpoint that reaches a .conf goes
# through here rather than being pasted together with a colon.
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

# Whatever an operator wrote, in the one form the tools accept. A bare address
# takes the fallback port, so `endpoint6: "2001:db8::1"` is a valid list entry
# when the node already names its port.
endpoint_normalise() {
    local value=${1:-} fallback=${2:-} host port
    [ -n "$value" ] || return 0
    host=$(endpoint_host "$value")
    port=$(endpoint_port "$value")
    [ -n "$port" ] || port=$fallback
    endpoint_format "$host" "$port"
}

# fd00:77::/64 -> fd00:77::1/64, the address the far end of every uplink holds.
first_host6() {
    local cidr=$1 net prefix
    net=${cidr%%/*}
    prefix=${cidr##*/}
    [ "$prefix" != "$cidr" ] || prefix=64
    printf '%s1/%s' "$net" "$prefix"
}

# True when host numbers can simply be appended to the subnet: fd00:77::/64 can,
# 2001:db8:0:0:1::/80 cannot. Auto-allocation only runs on the first kind —
# getting IPv6 arithmetic wrong in shell would hand two uplinks one address, and
# an explicit `address6` in the list is always available for the rest.
subnet6_appendable() {
    case ${1%%/*} in *::) return 0 ;; esac
    return 1
}

# The nth address of such a subnet, as the /128 one uplink terminates on.
subnet6_host() {
    local cidr=$1 n=$2
    subnet6_appendable "$cidr" || return 1
    printf '%s%x/128' "${cidr%%/*}" "$n"
}

# The last octet of an IPv4 address or CIDR, which is the host number inside a /24
# uplink subnet. Used to number the IPv6 half of the bridge in step with the IPv4
# one, so falling back to the slot index is what happens when the address is not
# the shape this can read.
addr_host4() {
    local host=${1%%/*}
    host=${host##*.}
    case $host in
        ''|*[!0-9]*) printf '%s' "${2:-0}" ;;
        *) printf '%s' "$host" ;;
    esac
}

wan_iface() {
    ip -4 route show default | awk '/default/ {print $5; exit}'
}

wan_iface6() {
    ip -6 route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Whether this host can reach the IPv6 internet at all. Dialling an exit node's
# IPv6 endpoint from a node that has no IPv6 route of its own is a tunnel that
# can never handshake, so the automatic family choice asks this first.
has_ipv6_egress() {
    [ -n "$(wan_iface6)" ]
}

# The host's own way to the internet, as the tail of an `ip route` command:
# "via 203.0.113.1 dev eth0" or, on a point-to-point link, "dev eth0".
#
# A route in another table cannot say "resolve this in the main table", so anything
# the entry node sends out of its own uplink instead of into the cascade has to name
# the next hop explicitly. Re-read rather than cached: a DHCP lease change moves it.
wan_nexthop() {
    ip -4 route show default | awk '
        /^default/ {
            gw = ""; dev = ""
            for (i = 2; i < NF; i++) {
                if ($i == "via") gw = $(i + 1)
                else if ($i == "dev") dev = $(i + 1)
            }
            if (dev == "") next
            if (gw == "") print "dev " dev
            else print "via " gw " dev " dev
            exit
        }'
}

# KEY=VALUE state file that survives container restarts. Everything the panel needs
# to hand out client configs is mirrored here.
params_load() {
    local file=$1
    [ -f "$file" ] || return 0
    set -a
    # shellcheck source=/dev/null
    . "$file"
    set +a
}

store_secret() {
    local file=$1 value=$2
    printf '%s\n' "$value" > "$file"
    chmod 0600 "$file"
}

params_store() {
    local file=$1; shift
    local tmp="${file}.tmp"
    : > "$tmp"
    local name value
    for name in "$@"; do
        value=${!name}
        # A CPS spec such as `<r 128>` would be read back as a redirection, so
        # anything outside the plain set is single-quoted. Values that do not need
        # it are written bare, which keeps the file readable by a panel that
        # predates the quoting.
        case $value in
            *[!A-Za-z0-9_.:,/+=-]*) printf "%s='%s'\n" "$name" "${value//\'/\'\\\'\'}" >> "$tmp" ;;
            *)                      printf '%s=%s\n' "$name" "$value" >> "$tmp" ;;
        esac
    done
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Protocol generations
# ---------------------------------------------------------------------------
#
# Which AmneziaWG generation a tunnel speaks is decided entirely by which
# [Interface] parameters the profile carries — that is also how AmneziaVPN and
# KeeneticOS tell them apart:
#
#   1.0   Jc Jmin Jmax S1 S2 H1-H4          any KeeneticOS from 4.2 Alpha 2 on
#   1.5   the same, plus I1                 KeeneticOS 5.1 Alpha 3 and newer
#   2.0   the same, plus I1, S3 and S4      KeeneticOS 5.1 Alpha 3 and newer
#
# AWG 3.0 — header protection, content padding, custom timings — is deliberately
# absent: no router firmware speaks it, and a 3.0 profile cannot be loaded into
# one at all.
#
# S1-S4 pad the four WireGuard message types and H1-H4 replace their type
# headers, so both ends of a tunnel must agree on them. Jc/Jmin/Jmax (junk
# packets) and I1-I5 (signature packets) are only ever built by the sender, so
# each side is free to use its own.

AWG_PROTOCOL_DEFAULT=${AWG_PROTOCOL_DEFAULT:-2.0}

# Every parameter any generation can carry, in the order a .conf lists them.
AWG_OBF_SUFFIXES="JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5"

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

# The parameters that make up a profile of one generation, in .conf order.
# I2-I5 are extras rather than part of the identity, so they are absent here and
# emitted only when an operator sets them.
awg_protocol_params() {
    case "${1:-1.0}" in
        1.0) printf 'JC JMIN JMAX S1 S2 H1 H2 H3 H4' ;;
        1.5) printf 'JC JMIN JMAX S1 S2 H1 H2 H3 H4 I1' ;;
        2.0) printf 'JC JMIN JMAX S1 S2 S3 S4 H1 H2 H3 H4 I1' ;;
    esac
}

# True when a generation carries the named parameter as part of its identity.
awg_protocol_has() {
    case " $(awg_protocol_params "$1") " in *" $2 "*) return 0 ;; esac
    return 1
}

# The .conf spelling of a parameter: Jc and Jmin are mixed case, the rest upper.
awg_param_label() {
    case $1 in
        JC)   printf 'Jc' ;;
        JMIN) printf 'Jmin' ;;
        JMAX) printf 'Jmax' ;;
        *)    printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Custom protocol signatures (I1-I5)
# ---------------------------------------------------------------------------
#
# A signature packet is sent ahead of every handshake so that the first thing a
# censor's classifier sees is a protocol it already passes. The far end never
# reads them, which is why a preset can be chosen per node — and handed to
# clients on a network where a different disguise works better.
AWG_CPS_PRESETS="quic dns random short none"

awg_cps_preset() {
    case "${1:-}" in
        # A QUIC v1 long header: 0xc3, version 1, then 8-byte connection ids.
        # UDP/443 is the entry node's default port, so this is the disguise that
        # matches what the traffic already looks like it should be.
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

# Resolves a preset name to its spec and leaves a literal spec untouched, so the
# same variable takes either.
awg_cps_spec() {
    local value=${1:-}
    case $value in
        '')  printf '' ;;
        *\<*) printf '%s' "$value" ;;
        *)   awg_cps_preset "$value" || return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Obfuscation profiles
# ---------------------------------------------------------------------------

# Fills in every parameter the generation needs and clears the ones it must not
# carry, so switching a running node down from 2.0 to 1.0 really does stop
# advertising S3, S4 and I1. The prefix keeps independent profiles per interface
# (AWG_ for the server interface, NODE_ for one cascade uplink). The third argument
# says what sits at the far end — app clients or another node — which decides how
# much padding is safe to hand out.
generate_obfuscation() {
    local p=$1 protocol peers=${3:-clients}
    protocol=$(awg_protocol "${2:-1.0}") || die "unknown AmneziaWG protocol: ${2:-}"
    case $peers in
        clients|nodes) ;;
        *) die "generate_obfuscation: peers must be 'clients' or 'nodes', got: ${peers}" ;;
    esac

    local suffix name keep
    for suffix in $AWG_OBF_SUFFIXES; do
        name="${p}${suffix}"
        case $suffix in
            # I2-I5 are opt-in extras rather than part of a generation's identity, so
            # whatever was configured stands — but only where signature packets exist.
            I[2-5]) awg_protocol_has "$protocol" I1 && keep=yes || keep=no ;;
            *)      awg_protocol_has "$protocol" "$suffix" && keep=yes || keep=no ;;
        esac
        [ "$keep" = yes ] || printf -v "$name" '%s' ''
    done

    local jc="${p}JC" jmin="${p}JMIN" jmax="${p}JMAX"
    local s1="${p}S1" s2="${p}S2" s3="${p}S3" s4="${p}S4"
    local h1="${p}H1" h2="${p}H2" h3="${p}H3" h4="${p}H4" i1="${p}I1"

    [ -n "${!jc:-}" ]   || printf -v "$jc"   '%s' "$(rand_range 3 10)"
    [ -n "${!jmin:-}" ] || printf -v "$jmin" '%s' "50"
    [ -n "${!jmax:-}" ] || printf -v "$jmax" '%s' "1000"
    [ -n "${!s1:-}" ]   || printf -v "$s1"   '%s' "$(rand_range 15 150)"

    if [ -z "${!s2:-}" ]; then
        local candidate
        while :; do
            candidate=$(rand_range 15 150)
            # AmneziaWG requires S1 + 56 != S2 so the init and response packets do
            # not end up the same length.
            [ "$(( ${!s1} + 56 ))" -ne "$candidate" ] && break
        done
        printf -v "$s2" '%s' "$candidate"
    fi

    if awg_protocol_has "$protocol" S3; then
        # S3 and S4 pad the cookie reply and every transport packet, so both ends have
        # to agree on them. The AmneziaVPN app drops them while importing a profile, so
        # an interface app clients dial pads by zero — otherwise the handshake still
        # completes and every transport packet the app sends is discarded as malformed,
        # which looks exactly like a tunnel that connects and carries nothing. A
        # node-to-node hop runs amneziawg-go at both ends, which honours them, and that
        # is the hop worth obfuscating anyway.
        if [ "$peers" = clients ]; then
            [ -n "${!s3:-}" ] || printf -v "$s3" '%s' '0'
            [ -n "${!s4:-}" ] || printf -v "$s4" '%s' '0'
        else
            [ -n "${!s3:-}" ] || printf -v "$s3" '%s' "$(rand_range 8 55)"
            [ -n "${!s4:-}" ] || printf -v "$s4" '%s' "$(rand_range 4 27)"
        fi
    fi

    local seen="" value
    for name in "$h1" "$h2" "$h3" "$h4"; do
        value="${!name:-}"
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
        local spec
        spec=$(awg_cps_spec "${!i1:-${AWG_CPS_DEFAULT:-quic}}") \
            || die "unknown signature packet preset: ${!i1:-} (try: ${AWG_CPS_PRESETS})"
        printf -v "$i1" '%s' "$spec"
    fi

    for suffix in $AWG_OBF_SUFFIXES; do
        export "${p}${suffix}"
    done
}

# Emits the [Interface] obfuscation lines for `awg setconf`. Only the parameters
# the generation defines are written: an extra one would move the profile to a
# generation the far end may not speak.
emit_obfuscation() {
    local p=$1 protocol suffix name value
    protocol=$(awg_protocol "${2:-1.0}") || die "unknown AmneziaWG protocol: ${2:-}"

    for suffix in $AWG_OBF_SUFFIXES; do
        name="${p}${suffix}"
        value=${!name:-}
        case $suffix in
            # An extra that was never configured is simply not a parameter.
            I[2-5]) awg_protocol_has "$protocol" I1 || continue ;;
            *)      awg_protocol_has "$protocol" "$suffix" || continue ;;
        esac
        # An empty value would be read as 0, which is a different profile from
        # not carrying the parameter at all.
        [ -n "$value" ] || continue
        printf '%s = %s\n' "$(awg_param_label "$suffix")" "$value"
    done
}

# Both of these return non-zero rather than exiting: bringing one uplink up may
# fail while the rest of the cascade keeps carrying traffic, so only the caller
# knows whether a failure is fatal.
#
# The fourth argument is the interface's address on the IPv6 half of the bridge,
# and is what makes a cascade hop dual-stack. It is optional: an installation that
# has not been given an IPv6 bridge subnet comes up exactly as it did before.
iface_up() {
    local iface=$1 addr=$2 mtu=$3 addr6=${4:-}
    ip link show "$iface" >/dev/null 2>&1 || return 1
    [ -z "$addr" ] || ip -4 address replace "$addr" dev "$iface" || return 1
    if [ -n "$addr6" ]; then
        # A host that disabled IPv6 globally disables it on every interface
        # created afterwards too, and the address would then be refused.
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1 || true
        # nodad: the two ends of a cascade hop are the only things on this link and
        # the address is ours by construction, so duplicate address detection has
        # nothing to find — it would only leave the address tentative, and
        # unusable as a source address, for a second after every rebuild.
        ip -6 address replace "$addr6" dev "$iface" nodad || return 1
    fi
    ip link set mtu "$mtu" up dev "$iface" || return 1
}

wait_for_socket() {
    local iface=$1 tries=0
    while [ ! -S "/var/run/amneziawg/${iface}.sock" ]; do
        tries=$((tries + 1))
        [ "$tries" -gt 100 ] && return 1
        sleep 0.1
    done
    return 0
}
