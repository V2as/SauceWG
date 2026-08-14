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
CASCADE_MTU=${CASCADE_MTU:-1380}
CASCADE_KEEPALIVE=${CASCADE_KEEPALIVE:-25}
CASCADE_TABLE=${CASCADE_TABLE:-451}
CASCADE_RULE_PRIORITY=${CASCADE_RULE_PRIORITY:-451}

SERVER_PARAMS_FILE="${AWG_CONFIG_DIR}/${AWG_IFACE}.params"
# Private keys live in their own files so the panel can mount the params read-only
# without gaining access to them.
SERVER_KEY_FILE="${AWG_CONFIG_DIR}/${AWG_IFACE}.key"

PIDS=()

# shellcheck source=uplinks.sh
. /usr/local/lib/awg-uplinks.sh

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

teardown() {
    log "shutting down"
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        uplinks_teardown
    fi
    ip link del "$AWG_IFACE" 2>/dev/null || true
    kill "${PIDS[@]}" 2>/dev/null || true
}

do_run() {
    local initial
    mkdir -p "$AWG_CONFIG_DIR" /var/run/amneziawg
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    trap teardown EXIT INT TERM

    ip link del "$AWG_IFACE" 2>/dev/null || true
    setup_server_iface

    if [ "$AWG_ROLE" != "entry" ] || [ "$CASCADE_ENABLED" != "true" ]; then
        setup_exit_routing
        log "node ready (role=${AWG_ROLE})"
        wait -n "${PIDS[@]}"
        log "an amneziawg-go process exited, stopping container"
        return
    fi

    uplinks_parse
    [ "$(uplink_count)" -gt 0 ] || die "CASCADE_ENABLED=true but no exit node is configured"

    uplinks_setup_all
    uplinks_routing_base

    # Start on the highest-priority uplink; the monitor corrects the choice as soon
    # as it has enough health samples to know better.
    uplinks_read_control
    initial=$(uplinks_select)
    [ "$initial" -ge 0 ] || initial=0
    uplink_activate "$initial"
    uplinks_write_state

    uplinks_monitor &
    PIDS+=("$!")

    log "node ready (role=entry, uplinks=$(uplink_count))"
    wait -n "${PIDS[@]}"
    log "a node process exited, stopping container"
}

do_healthcheck() {
    [ -S "/var/run/amneziawg/${AWG_IFACE}.sock" ] || exit 1
    ip link show "$AWG_IFACE" >/dev/null 2>&1 || exit 1
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        # The uplinks are only healthy as a group: at least the active one must exist.
        [ -f "$UPLINK_STATE_FILE" ] || exit 1
        jq -e '.active != null' "$UPLINK_STATE_FILE" >/dev/null 2>&1 || exit 1
    fi
    exit 0
}

case "${1:-run}" in
    run) do_run ;;
    healthcheck) do_healthcheck ;;
    *) exec "$@" ;;
esac
