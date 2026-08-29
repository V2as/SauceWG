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
SERVER_PID=0

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

    local suffix
    for suffix in $AWG_OBF_SUFFIXES; do
        local env_name="AWG_${suffix}" saved_name="SERVER_${suffix}"
        if [ -z "${!env_name:-}" ] && [ -n "${!saved_name:-}" ]; then
            printf -v "$env_name" '%s' "${!saved_name}"
        fi
    done

    # An installation that predates protocol selection has a profile but no
    # generation recorded, and it is serving 1.0 clients right now — so it stays on
    # 1.0 until someone asks for something else. Only a genuinely new interface
    # gets the current default.
    if [ -z "${AWG_PROTOCOL:-}" ]; then
        if [ -n "${SERVER_PROTOCOL:-}" ]; then
            AWG_PROTOCOL=$SERVER_PROTOCOL
        elif [ -n "${SERVER_S1:-}" ]; then
            AWG_PROTOCOL=1.0
            log "no protocol recorded for ${AWG_IFACE}; keeping the existing AmneziaWG 1.0 profile"
        else
            AWG_PROTOCOL=$AWG_PROTOCOL_DEFAULT
        fi
    fi
    SERVER_PROTOCOL=$(awg_protocol "$AWG_PROTOCOL") \
        || die "AWG_PROTOCOL=${AWG_PROTOCOL} is not an AmneziaWG generation this node can serve (1.0, 1.5 or 2.0)"
    AWG_PROTOCOL=$SERVER_PROTOCOL

    # Only an entry node's server interface is dialled by app clients; an exit node's
    # is dialled by the entry node, which speaks the protocol in full.
    local peers=nodes
    [ "$AWG_ROLE" = "entry" ] && peers=clients
    generate_obfuscation "AWG_" "$SERVER_PROTOCOL" "$peers"

    # params_store reads these by name, so shellcheck cannot see the use.
    # shellcheck disable=SC2034
    {
        SERVER_PORT=$AWG_PORT
        SERVER_SUBNET=$AWG_SUBNET
        SERVER_MTU=$AWG_MTU
    }
    SERVER_ADDRESS=$(first_host "$AWG_SUBNET")

    # The panel reads these to render client profiles, so every parameter of the
    # generation in force has to be mirrored here — including the ones that were
    # cleared, so it stops handing out a profile the interface no longer speaks.
    local stored=(SERVER_PUBLIC_KEY SERVER_PORT SERVER_SUBNET SERVER_ADDRESS SERVER_MTU SERVER_PROTOCOL)
    local source_name
    for suffix in $AWG_OBF_SUFFIXES; do
        source_name="AWG_${suffix}"
        printf -v "SERVER_${suffix}" '%s' "${!source_name:-}"
        stored+=("SERVER_${suffix}")
    done
    params_store "$SERVER_PARAMS_FILE" "${stored[@]}"

    local conf="${AWG_CONFIG_DIR}/${AWG_IFACE}.conf"
    {
        echo "[Interface]"
        echo "PrivateKey = ${SERVER_PRIVATE_KEY}"
        echo "ListenPort = ${AWG_PORT}"
        emit_obfuscation "AWG_" "$SERVER_PROTOCOL"
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
    SERVER_PID=$!
    PIDS+=("$SERVER_PID")
    wait_for_socket "$AWG_IFACE" || die "timed out waiting for the ${AWG_IFACE} UAPI socket"
    awg setconf "$AWG_IFACE" "$conf"
    iface_up "$AWG_IFACE" "$SERVER_ADDRESS" "$AWG_MTU" \
        || die "could not bring ${AWG_IFACE} up on ${SERVER_ADDRESS}"
    ip -4 route replace "$AWG_SUBNET" dev "$AWG_IFACE"
    log "${AWG_IFACE} up on ${SERVER_ADDRESS} port ${AWG_PORT} speaking AmneziaWG ${SERVER_PROTOCOL} (pub ${SERVER_PUBLIC_KEY})"
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
    local i
    log "shutting down"
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        for i in "${!UP_PID[@]}"; do
            [ "${UP_PID[$i]}" -gt 0 ] 2>/dev/null && kill "${UP_PID[$i]}" 2>/dev/null
        done
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

    # An empty list still yields one unpaired uplink, so the panel comes up — and can
    # be used to add the first exit node — before any exit node exists.
    uplinks_parse || die "CASCADE_ENABLED=true but the exit node list is unusable: ${CONFIG_ERROR}"
    direct_parse || true

    uplinks_setup_all
    uplinks_routing_base

    # Start on the highest-priority uplink; the monitor corrects the choice as soon
    # as it has enough health samples to know better. Nothing usable yet — a fresh
    # entry node with no exit node paired to it, or a restart while every exit node
    # is down — goes straight to the fallback.
    uplinks_read_control
    initial=$(uplinks_select)
    if [ "$initial" -ge 0 ]; then
        uplink_activate "$initial"
    else
        uplinks_fallback
    fi
    uplinks_write_state

    log "node ready (role=entry, uplinks=$(uplink_count))"
    # The monitor stays in the foreground: it has to be the parent of every uplink
    # process so it can restart and reap them while reconfiguring the cascade.
    uplinks_monitor
    log "the node monitor exited, stopping container"
}

do_healthcheck() {
    [ -S "/var/run/amneziawg/${AWG_IFACE}.sock" ] || exit 1
    ip link show "$AWG_IFACE" >/dev/null 2>&1 || exit 1
    if [ "$AWG_ROLE" = "entry" ] && [ "$CASCADE_ENABLED" = "true" ]; then
        # The uplinks are only healthy as a group: either one of them is carrying
        # client traffic, or the entry node is carrying it itself because it was
        # configured to. Blocking is the one state that is not healthy — the node is
        # up but no client is getting anywhere.
        [ -f "$UPLINK_STATE_FILE" ] || exit 1
        jq -e '.active != null or (.fallback_active == true and .fallback == "direct")' \
            "$UPLINK_STATE_FILE" >/dev/null 2>&1 || exit 1
    fi
    exit 0
}

case "${1:-run}" in
    run) do_run ;;
    healthcheck) do_healthcheck ;;
    *) exec "$@" ;;
esac
