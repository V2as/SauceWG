#!/usr/bin/env bash
# Shared helpers for the AmneziaWG legacy node entrypoint.

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

wan_iface() {
    ip -4 route show default | awk '/default/ {print $5; exit}'
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
    local name
    for name in "$@"; do
        printf '%s=%s\n' "$name" "${!name}" >> "$tmp"
    done
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
}

# Fills in any unset AmneziaWG legacy obfuscation parameter with a sane random value.
# Prefix lets us keep independent parameter sets per interface (AWG_ / CASCADE_).
generate_obfuscation() {
    local p=$1
    local jc="${p}JC" jmin="${p}JMIN" jmax="${p}JMAX" s1="${p}S1" s2="${p}S2"
    local h1="${p}H1" h2="${p}H2" h3="${p}H3" h4="${p}H4"

    [ -n "${!jc}" ]   || printf -v "$jc"   '%s' "$(rand_range 3 10)"
    [ -n "${!jmin}" ] || printf -v "$jmin" '%s' "50"
    [ -n "${!jmax}" ] || printf -v "$jmax" '%s' "1000"
    [ -n "${!s1}" ]   || printf -v "$s1"   '%s' "$(rand_range 15 150)"

    if [ -z "${!s2}" ]; then
        local candidate
        while :; do
            candidate=$(rand_range 15 150)
            # AmneziaWG requires S1 + 56 != S2 so init and response packets differ in size.
            [ "$((${!s1} + 56))" -ne "$candidate" ] && break
        done
        printf -v "$s2" '%s' "$candidate"
    fi

    local seen="" name value
    for name in "$h1" "$h2" "$h3" "$h4"; do
        value="${!name}"
        if [ -z "$value" ]; then
            while :; do
                value=$(rand_range 5 2147483647)
                case " $seen " in *" $value "*) continue ;; esac
                break
            done
            printf -v "$name" '%s' "$value"
        fi
        seen="$seen $value"
    done
    export "${jc?}" "${jmin?}" "${jmax?}" "${s1?}" "${s2?}" "${h1?}" "${h2?}" "${h3?}" "${h4?}"
}

# Emits the [Interface] obfuscation lines for `awg setconf`.
emit_obfuscation() {
    local p=$1
    local jc="${p}JC" jmin="${p}JMIN" jmax="${p}JMAX" s1="${p}S1" s2="${p}S2"
    local h1="${p}H1" h2="${p}H2" h3="${p}H3" h4="${p}H4"
    cat <<EOF
Jc = ${!jc}
Jmin = ${!jmin}
Jmax = ${!jmax}
S1 = ${!s1}
S2 = ${!s2}
H1 = ${!h1}
H2 = ${!h2}
H3 = ${!h3}
H4 = ${!h4}
EOF
}

iface_up() {
    local iface=$1 addr=$2 mtu=$3
    ip link show "$iface" >/dev/null 2>&1 || die "interface $iface was not created"
    ip -4 address replace "$addr" dev "$iface"
    ip link set mtu "$mtu" up dev "$iface"
}

wait_for_socket() {
    local iface=$1 tries=0
    while [ ! -S "/var/run/amneziawg/${iface}.sock" ]; do
        tries=$((tries + 1))
        [ "$tries" -gt 100 ] && die "timed out waiting for ${iface} UAPI socket"
        sleep 0.1
    done
}
