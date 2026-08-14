#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. /usr/local/lib/awg-lib.sh

AWG_ROLE=${AWG_ROLE:-exit}
AWG_CONFIG_DIR=${AWG_CONFIG_DIR:-/etc/amnezia/amneziawg}
AWG_IFACE=${AWG_IFACE:-awg0}
AWG_PORT=${AWG_PORT:-51820}
AWG_SUBNET=${AWG_SUBNET:-10.8.0.0/24}
AWG_MTU=${AWG_MTU:-1420}

CASCADE_ENABLED=${CASCADE_ENABLED:-false}
CASCADE_IFACE=${CASCADE_IFACE:-awg1}
CASCADE_ADDRESS=${CASCADE_ADDRESS:-10.77.0.2/32}
CASCADE_MTU=${CASCADE_MTU:-1380}
CASCADE_KEEPALIVE=${CASCADE_KEEPALIVE:-25}
CASCADE_TABLE=${CASCADE_TABLE:-451}
CASCADE_RULE_PRIORITY=${CASCADE_RULE_PRIORITY:-451}

SERVER_PARAMS_FILE="${AWG_CONFIG_DIR}/${AWG_IFACE}.params"
CASCADE_PARAMS_FILE="${AWG_CONFIG_DIR}/${CASCADE_IFACE}.params"
# Private keys live in their own files so the panel can mount the params read-only
# without gaining access to them.
SERVER_KEY_FILE="${AWG_CONFIG_DIR}/${AWG_IFACE}.key"
CASCADE_KEY_FILE="${AWG_CONFIG_DIR}/${CASCADE_IFACE}.key"

PIDS=()

# ---------------------------------------------------------------------------
# Server interface (clients on the entry node, the entry node on the exit node)
# ---------------------------------------------------------------------------

setup_server_iface() {
    params_load "$SERVER_PARAMS_FILE"

    # Env always wins over persisted state so the operator can pin values in .env.
    if [ -z "${AWG_PRIVATE_KEY:-}" ] && [ -f "$SERVER_KEY_FILE" ]; then
        AWG_PRIVATE_KEY=$(cat "$SERVER_KEY_FILE")
    fi
    if [ -z "${AWG_PRIVATE_KEY:-}" ]; then
        AWG_PRIVATE_KEY=$(awg_genkey)
        log "generated a new private key for ${AWG_IFACE}"
    fi
    store_secret "$SERVER_KEY_FILE" "$AWG_PRIVATE_KEY"
    SERVER_PRIVATE_KEY=$AWG_PRIVATE_KEY
    SERVER_PUBLIC_KEY=$(awg_pubkey "$SERVER_PRIVATE_KEY")

    for suffix in JC JMIN JMAX S1 S2 H1 H2 H3 H4; do
        local env_name="AWG_${suffix}" saved_name="SERVER_${suffix}"
        if [ -z "${!env_name:-}" ] && [ -n "${!saved_name:-}" ]; then
            printf -v "$env_name" '%s' "${!saved_name}"
        fi
    done
    generate_obfuscation "AWG_"

    # params_store reads these by name, so shellcheck cannot see the use.
    # shellcheck disable=SC2034
    {
        SERVER_JC=$AWG_JC; SERVER_JMIN=$AWG_JMIN; SERVER_JMAX=$AWG_JMAX
        SERVER_S1=$AWG_S1; SERVER_S2=$AWG_S2
        SERVER_H1=$AWG_H1; SERVER_H2=$AWG_H2; SERVER_H3=$AWG_H3; SERVER_H4=$AWG_H4
        SERVER_PORT=$AWG_PORT
        SERVER_SUBNET=$AWG_SUBNET
        SERVER_MTU=$AWG_MTU
    }
    SERVER_ADDRESS=$(first_host "$AWG_SUBNET")

    params_store "$SERVER_PARAMS_FILE" \
        SERVER_PUBLIC_KEY SERVER_PORT SERVER_SUBNET SERVER_ADDRESS SERVER_MTU \
        SERVER_JC SERVER_JMIN SERVER_JMAX SERVER_S1 SERVER_S2 SERVER_H1 SERVER_H2 SERVER_H3 SERVER_H4

    local conf="${AWG_CONFIG_DIR}/${AWG_IFACE}.conf"
    {
        echo "[Interface]"
        echo "PrivateKey = ${SERVER_PRIVATE_KEY}"
        echo "ListenPort = ${AWG_PORT}"
        emit_obfuscation "AWG_"
        # Static peers (the cascade uplink on an exit node). Runtime clients are
        # managed by the panel over the UAPI socket and are deliberately not listed.
        if [ -n "${AWG_PEER_PUBLIC_KEY:-}" ]; then
            echo
            echo "[Peer]"
            echo "PublicKey = ${AWG_PEER_PUBLIC_KEY}"
            [ -n "${AWG_PEER_PSK:-}" ] && echo "PresharedKey = ${AWG_PEER_PSK}"
            echo "AllowedIPs = ${AWG_PEER_ALLOWED_IPS:-${AWG_SUBNET}}"
        fi
        if [ -f "${AWG_CONFIG_DIR}/peers.conf" ]; then
            echo
            cat "${AWG_CONFIG_DIR}/peers.conf"
        fi
    } > "$conf"
    chmod 0600 "$conf"

    amneziawg-go -f "$AWG_IFACE" &
    PIDS+=("$!")
    wait_for_socket "$AWG_IFACE"
    awg setconf "$AWG_IFACE" "$conf"
    iface_up "$AWG_IFACE" "$SERVER_ADDRESS" "$AWG_MTU"
    ip -4 route replace "$AWG_SUBNET" dev "$AWG_IFACE"
    log "${AWG_IFACE} up on ${SERVER_ADDRESS} port ${AWG_PORT} (pub ${SERVER_PUBLIC_KEY})"
}

# ---------------------------------------------------------------------------
# Cascade uplink: entry node -> exit node
# ---------------------------------------------------------------------------

setup_cascade_iface() {
    params_load "$CASCADE_PARAMS_FILE"

    if [ -z "${CASCADE_PRIVATE_KEY:-}" ] && [ -f "$CASCADE_KEY_FILE" ]; then
        CASCADE_PRIVATE_KEY=$(cat "$CASCADE_KEY_FILE")
    fi
    if [ -z "${CASCADE_PRIVATE_KEY:-}" ]; then
        CASCADE_PRIVATE_KEY=$(awg_genkey)
        log "generated a new private key for ${CASCADE_IFACE}"
    fi
    store_secret "$CASCADE_KEY_FILE" "$CASCADE_PRIVATE_KEY"

    for suffix in JC JMIN JMAX S1 S2 H1 H2 H3 H4; do
        local env_name="CASCADE_${suffix}" saved_name="UPLINK_${suffix}"
        if [ -z "${!env_name:-}" ] && [ -n "${!saved_name:-}" ]; then
            printf -v "$env_name" '%s' "${!saved_name}"
        fi
    done
    generate_obfuscation "CASCADE_"

    UPLINK_PUBLIC_KEY=$(awg_pubkey "$CASCADE_PRIVATE_KEY")
    # params_store reads these by name, so shellcheck cannot see the use.
    # shellcheck disable=SC2034
    {
        UPLINK_ENDPOINT=${CASCADE_ENDPOINT:-}
        UPLINK_ADDRESS=$CASCADE_ADDRESS
        UPLINK_JC=$CASCADE_JC; UPLINK_JMIN=$CASCADE_JMIN; UPLINK_JMAX=$CASCADE_JMAX
        UPLINK_S1=$CASCADE_S1; UPLINK_S2=$CASCADE_S2
        UPLINK_H1=$CASCADE_H1; UPLINK_H2=$CASCADE_H2; UPLINK_H3=$CASCADE_H3; UPLINK_H4=$CASCADE_H4
    }

    params_store "$CASCADE_PARAMS_FILE" \
        UPLINK_PUBLIC_KEY UPLINK_ENDPOINT UPLINK_ADDRESS \
        UPLINK_JC UPLINK_JMIN UPLINK_JMAX UPLINK_S1 UPLINK_S2 UPLINK_H1 UPLINK_H2 UPLINK_H3 UPLINK_H4

    local conf="${AWG_CONFIG_DIR}/${CASCADE_IFACE}.conf"
    {
        echo "[Interface]"
        echo "PrivateKey = ${CASCADE_PRIVATE_KEY}"
        emit_obfuscation "CASCADE_"
        # During first-time pairing the exit node's key is not known yet. The interface
        # still comes up (peerless) so the uplink public key gets published and the
        # kill switch stays in force.
        if [ -n "${CASCADE_PEER_PUBLIC_KEY:-}" ] && [ -n "${CASCADE_ENDPOINT:-}" ]; then
            echo
            echo "[Peer]"
            echo "PublicKey = ${CASCADE_PEER_PUBLIC_KEY}"
            [ -n "${CASCADE_PEER_PSK:-}" ] && echo "PresharedKey = ${CASCADE_PEER_PSK}"
            echo "AllowedIPs = 0.0.0.0/0"
            echo "Endpoint = ${CASCADE_ENDPOINT}"
            echo "PersistentKeepalive = ${CASCADE_KEEPALIVE}"
        else
            log "cascade peer is not configured yet; ${CASCADE_IFACE} starts without a peer"
        fi
    } > "$conf"
    chmod 0600 "$conf"

    amneziawg-go -f "$CASCADE_IFACE" &
    PIDS+=("$!")
    wait_for_socket "$CASCADE_IFACE"
    awg setconf "$CASCADE_IFACE" "$conf"
    iface_up "$CASCADE_IFACE" "$CASCADE_ADDRESS" "$CASCADE_MTU"
    log "${CASCADE_IFACE} up towards ${CASCADE_ENDPOINT:-<unpaired>} (pub ${UPLINK_PUBLIC_KEY})"
}

# ---------------------------------------------------------------------------
# Forwarding / NAT
# ---------------------------------------------------------------------------

setup_exit_routing() {
    local wan
    wan=${WAN_IFACE:-$(wan_iface)}
    [ -n "$wan" ] || die "could not determine the WAN interface"
    log "exit routing via ${wan}"

    iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$wan" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$wan" -j MASQUERADE
    iptables -C FORWARD -i "$AWG_IFACE" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$AWG_IFACE" -j ACCEPT
    iptables -C FORWARD -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t mangle -C FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

setup_entry_routing() {
    # Client traffic leaves only through the cascade uplink. Policy routing keeps the
    # host's own default route (SSH, panel, the uplink handshake itself) untouched.
    ip route replace default dev "$CASCADE_IFACE" table "$CASCADE_TABLE"
    ip rule del from "$AWG_SUBNET" lookup "$CASCADE_TABLE" 2>/dev/null || true
    ip rule add from "$AWG_SUBNET" lookup "$CASCADE_TABLE" priority "$CASCADE_RULE_PRIORITY"

    iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$CASCADE_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$CASCADE_IFACE" -j MASQUERADE

    iptables -C FORWARD -i "$AWG_IFACE" -o "$CASCADE_IFACE" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$AWG_IFACE" -o "$CASCADE_IFACE" -j ACCEPT
    iptables -C FORWARD -i "$CASCADE_IFACE" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$CASCADE_IFACE" -o "$AWG_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    if [ "${CASCADE_KILLSWITCH:-true}" = "true" ]; then
        # Without the uplink there is no path out, so a dead tunnel cannot leak the
        # entry node's own address.
        iptables -C FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null \
            || iptables -A FORWARD -i "$AWG_IFACE" -j REJECT --reject-with icmp-net-unreachable
    fi

    iptables -t mangle -C FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -i "$AWG_IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

teardown() {
    log "shutting down"
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        ip rule del from "$AWG_SUBNET" lookup "$CASCADE_TABLE" 2>/dev/null || true
        ip route flush table "$CASCADE_TABLE" 2>/dev/null || true
        ip link del "$CASCADE_IFACE" 2>/dev/null || true
    fi
    ip link del "$AWG_IFACE" 2>/dev/null || true
    kill "${PIDS[@]}" 2>/dev/null || true
}

do_run() {
    mkdir -p "$AWG_CONFIG_DIR" /var/run/amneziawg
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    trap teardown EXIT INT TERM

    ip link del "$AWG_IFACE" 2>/dev/null || true
    ip link del "$CASCADE_IFACE" 2>/dev/null || true

    setup_server_iface
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        setup_cascade_iface
        setup_entry_routing
    else
        setup_exit_routing
    fi

    log "node ready (role=${AWG_ROLE})"
    wait -n "${PIDS[@]}"
    log "an amneziawg-go process exited, stopping container"
}

do_healthcheck() {
    [ -S "/var/run/amneziawg/${AWG_IFACE}.sock" ] || exit 1
    ip link show "$AWG_IFACE" >/dev/null 2>&1 || exit 1
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        ip link show "$CASCADE_IFACE" >/dev/null 2>&1 || exit 1
    fi
    exit 0
}

case "${1:-run}" in
    run) do_run ;;
    healthcheck) do_healthcheck ;;
    *) exec "$@" ;;
esac
