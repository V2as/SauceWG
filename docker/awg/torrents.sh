#!/usr/bin/env bash
# Blocking BitTorrent in the traffic this node forwards.
#
# An exit node is the address a swarm sees, and a datacentre answers a copyright
# notice by suspending the server rather than by asking who was behind it. One
# client seeding for an evening is the whole node gone, and with it every other
# client on it — so this has to be the kind of block that holds, not the kind
# that discourages.
#
# It runs where client traffic is still in the clear: the forwarding path of the
# node, after AmneziaWG has decrypted what a client sent and before anything is
# re-encrypted into an uplink. That is the one place a client's traffic exists as
# plain IP, so it is the only place a signature can be read at all. The same code
# runs on an exit node, where the interface faces an entry node instead of a
# client — the ladder does not care which.
#
# The rules live in the `mangle` table rather than in `filter`. Client traffic in
# `filter/FORWARD` is a set of ACCEPT rules that uplinks.sh inserts at position 1
# whenever a path appears, so anything placed there would be jumped over the
# moment an exit node was added. `mangle/FORWARD` is traversed before `filter` in
# its entirety, which makes the ordering a property of the kernel rather than of
# who wrote a rule last.
#
# Only IPv4 is filtered, because only IPv4 is carried: the tunnel interfaces are
# brought up with `ip -4 address` and have no IPv6 address to forward from.
#
# ---------------------------------------------------------------------------
# What is actually being blocked
# ---------------------------------------------------------------------------
#
# BitTorrent is two problems, and only one of them is hard.
#
# *Discovery* — finding the peers of a swarm — is not encrypted by anything and
# cannot be, because the parties do not share a secret yet. A DHT query is
# bencoded ASCII, a UDP tracker announce opens with a fixed 64-bit constant, an
# HTTP announce is a query string with `info_hash=` in it. Each is a signature no
# client can drop and still work, and killing them means a client never learns an
# address to talk to and the swarm never learns this node's. That is what stops
# the abuse notice: a monitoring peer cannot see an address that never announced.
#
# *The peer wire* is the hard one, because MSE encrypts it from the first byte
# with a key derived from the info hash. There is no signature to match. Two
# things are done about it. uTP — which is what a modern client opens a
# connection with before MSE starts — is a 20-byte header in a UDP datagram with
# a fixed first byte, so its setup is matched by shape and never gets as far as
# being encrypted. And every address caught speaking any part of the protocol is
# remembered in an ipset, so the *next* connection to that peer is dropped
# without being inspected, encrypted or not.
#
# What is left after that is a TCP/MSE connection to an address the client
# already knew, on a port nothing else uses. `strict` closes it: outbound TCP and
# UDP are refused except to the ports real services answer on. That is a general
# egress policy rather than a torrent signature, which is exactly why it is a
# separate mode — it is the only layer here that can inconvenience somebody who
# was not torrenting.
#
# The two halves are complementary rather than redundant, and the reason is worth
# stating: the port policy catches what has no signature, and the signatures
# catch what is on an allowed port. A client configured to run uTP and DHT over
# UDP/443 to hide inside QUIC defeats the port policy and walks straight into the
# shape and bencode rules, which never look at a port.

TORRENT_BLOCK=${TORRENT_BLOCK:-}
TORRENT_BLOCK_FILE=${TORRENT_BLOCK_FILE:-/etc/amnezia/host/torrent-block.json}
TORRENT_STATE_FILE=${TORRENT_STATE_FILE:-/var/run/amneziawg/torrents.json}

# How long an address caught speaking BitTorrent stays blocked for. Long enough
# that a client working through the peers of a swarm keeps meeting the same wall,
# short enough that an address which changes hands is not blocked for ever.
TORRENT_PEER_TIMEOUT=${TORRENT_PEER_TIMEOUT:-3600}
# How long a client stays on the list of who tripped the guard. This one is only
# ever read, never enforced, so it is the reporting window rather than a block.
TORRENT_CLIENT_TIMEOUT=${TORRENT_CLIENT_TIMEOUT:-86400}
TORRENT_PEER_MAX=${TORRENT_PEER_MAX:-262144}

# Where the ladder stops looking inside a connection. Everything it matches is in
# the opening exchange — a handshake, an announce, a DHT query — so scanning
# further is paying for bytes that cannot match. Without this bound the string
# matches would run over every byte the node forwards, which on a userspace
# tunnel is the difference between a filter and a bottleneck.
TORRENT_SCAN_PACKETS=${TORRENT_SCAN_PACKETS:-32}

# The ports `strict` leaves open. Deliberately not a list of everything that
# might be useful: this mode exists for an operator who has already decided that
# a service nobody named is worth less than a suspended node.
#
# 500, 4500 and 51820 are absent on purpose. A client that can open its own VPN
# out of the tunnel can torrent inside it, and no packet filter downstream of
# that will ever see it. Add them back if the users of a node need them more than
# the node needs the guarantee.
TORRENT_TCP_PORTS=${TORRENT_TCP_PORTS:-20,21,22,25,53,80,110,143,443,465,587,853,993,995,1935,3128,3478,5222,5223,5228:5230,8080,8443}
TORRENT_UDP_PORTS=${TORRENT_UDP_PORTS:-53,67,68,80,123,443,853,3478:3481,5060,19302:19309}

TORRENT_CHAIN=SAUCEWG_TORRENT
TORRENT_SCAN_CHAIN=SAUCEWG_TORRENT_SCAN
TORRENT_IN_CHAIN=SAUCEWG_TORRENT_IN
# Caught speaking the protocol: remember the peer, note the client, drop.
TORRENT_HIT_CHAIN=SAUCEWG_TORRENT_HIT
# Refused for what it is rather than for who it was talking to: note the client
# and drop, but do not blacklist the destination. A DNS query for a tracker goes
# to a resolver, and blacklisting the resolver would take the client off the
# internet.
TORRENT_CUT_CHAIN=SAUCEWG_TORRENT_CUT

TORRENT_PEER_SET=${TORRENT_PEER_SET:-saucewg-torrent-peers}
TORRENT_CLIENT_SET=${TORRENT_CLIENT_SET:-saucewg-torrent-clients}

# off | on | strict, and where that was decided.
TORRENT_MODE=off
TORRENT_SOURCE=none
# What is wrong with the setting, and separately what was wrong with installing
# it. They are kept apart because they have different lifetimes: a bad file is
# fixed by editing it, a missing kernel module is not fixed at all.
TORRENT_ERROR=""
TORRENT_BUILD_ERROR=""
# What is installed right now, and the signature of it, so a tick that changes
# nothing costs one iptables call rather than sixty.
TORRENT_ACTIVE=false
TORRENT_APPLIED=""
TORRENT_RULES=0
TORRENT_REFUSED=0

# Which matches this kernel actually has. Probed once, because a missing module
# is a rule that quietly fails to install rather than an error anyone would
# otherwise see, and an operator who asked for this deserves to be told which
# half of it they got.
TORRENT_CAPS_PROBED=false
TORRENT_CAP_STRING=false
TORRENT_CAP_COMMENT=false
TORRENT_CAP_CONNBYTES=false
TORRENT_CAP_SET=false

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

torrent_normalise_mode() {
    case $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]') in
        strict|paranoid)                printf 'strict' ;;
        on|true|1|yes|enabled|standard) printf 'on' ;;
        off|false|0|no|disabled|'')     printf 'off' ;;
        *) return 1 ;;
    esac
}

torrent_config_source() {
    if [ -n "${TORRENT_BLOCK:-}" ]; then
        printf 'env'
    elif [ -f "$TORRENT_BLOCK_FILE" ]; then
        printf 'file'
    else
        printf 'none'
    fi
}

# The file the panel writes: {"enabled": true, "mode": "strict"}. `enabled` and
# `mode` are kept apart rather than folded into one field so that turning the
# guard off from the UI and back on does not lose which mode was chosen — the
# switch and the dial are different controls.
torrent_parse() {
    local mode raw enabled

    TORRENT_SOURCE=$(torrent_config_source)
    TORRENT_ERROR=""

    case $TORRENT_SOURCE in
        env)
            if ! mode=$(torrent_normalise_mode "$TORRENT_BLOCK"); then
                TORRENT_ERROR="TORRENT_BLOCK=${TORRENT_BLOCK} is not one of off, on or strict, so nothing is being blocked"
                log "torrents: $TORRENT_ERROR"
                TORRENT_MODE=off
                return 0
            fi
            ;;
        file)
            raw=$(cat "$TORRENT_BLOCK_FILE" 2>/dev/null) || raw=""
            if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
                TORRENT_ERROR="${TORRENT_BLOCK_FILE} is not a JSON object; keeping the setting that is already in force"
                log "torrents: $TORRENT_ERROR"
                return 1
            fi
            enabled=$(printf '%s' "$raw" | jq -r 'if has("enabled") then (.enabled | tostring) else "true" end')
            mode=$(printf '%s' "$raw" | jq -r '.mode // "on"')
            if [ "$enabled" != "true" ]; then
                mode=off
            elif ! mode=$(torrent_normalise_mode "$mode"); then
                TORRENT_ERROR="'$(printf '%s' "$raw" | jq -r '.mode')' is not one of on or strict, so the standard mode is in force"
                log "torrents: $TORRENT_ERROR"
                mode=on
            fi
            ;;
        *) mode=off ;;
    esac

    TORRENT_MODE=$mode
    return 0
}

torrent_config_mtime() {
    [ -f "$TORRENT_BLOCK_FILE" ] || { printf '0'; return; }
    stat -c %Y "$TORRENT_BLOCK_FILE" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# What the kernel can match
# ---------------------------------------------------------------------------

torrent_try_match() {
    iptables -t mangle -A "${TORRENT_CHAIN}_PROBE" "$@" -j RETURN 2>/dev/null
}

torrent_probe_caps() {
    [ "$TORRENT_CAPS_PROBED" = true ] && return 0
    TORRENT_CAPS_PROBED=true

    iptables -t mangle -N "${TORRENT_CHAIN}_PROBE" 2>/dev/null \
        || iptables -t mangle -F "${TORRENT_CHAIN}_PROBE" 2>/dev/null || return 0

    torrent_try_match -p udp -m string --string saucewg --algo bm --from 0 --to 32 \
        && TORRENT_CAP_STRING=true
    torrent_try_match -m comment --comment saucewg-probe \
        && TORRENT_CAP_COMMENT=true
    torrent_try_match -m connbytes --connbytes 0:8 --connbytes-dir original --connbytes-mode packets \
        && TORRENT_CAP_CONNBYTES=true

    # The sets have to exist before a rule can name one, and creating them is
    # itself the test of whether this kernel has ip_set at all.
    if command -v ipset >/dev/null 2>&1 \
        && ipset create "$TORRENT_PEER_SET" hash:ip family inet \
            timeout "$TORRENT_PEER_TIMEOUT" maxelem "$TORRENT_PEER_MAX" counters -exist 2>/dev/null \
        && ipset create "$TORRENT_CLIENT_SET" hash:ip family inet \
            timeout "$TORRENT_CLIENT_TIMEOUT" counters -exist 2>/dev/null \
        && torrent_try_match -m set --match-set "$TORRENT_PEER_SET" dst; then
        TORRENT_CAP_SET=true
    fi

    iptables -t mangle -F "${TORRENT_CHAIN}_PROBE" 2>/dev/null || true
    iptables -t mangle -X "${TORRENT_CHAIN}_PROBE" 2>/dev/null || true

    log "torrents: kernel matches — string=${TORRENT_CAP_STRING} ipset=${TORRENT_CAP_SET} connbytes=${TORRENT_CAP_CONNBYTES} comment=${TORRENT_CAP_COMMENT}"
    return 0
}

# ---------------------------------------------------------------------------
# The ladder
# ---------------------------------------------------------------------------

# One rule, labelled with the layer it belongs to so that `iptables-save -c` can
# report how much each of them is actually catching.
#
# A rule the kernel refuses is counted and skipped, never fatal, and the count is
# reported: half a ladder still blocks, and an operator who asked for this is
# owed the knowledge of which half they got rather than a container that will not
# start. Hence the unconditional success — a caller is a bare statement under
# `set -e`, and a failing one would take the node down over a missing module.
tg_rule() {
    local chain=$1 layer=$2 target=$3
    shift 3
    local label=()
    [ "$TORRENT_CAP_COMMENT" != true ] || label=(-m comment --comment "saucewg:torrent:${layer}")
    if iptables -t mangle -A "$chain" "$@" ${label[@]+"${label[@]}"} -j "$target" 2>/dev/null; then
        TORRENT_RULES=$((TORRENT_RULES + 1))
    else
        TORRENT_REFUSED=$((TORRENT_REFUSED + 1))
    fi
    return 0
}

# A pattern inside a bounded window of the packet. The window is measured from
# the start of the IP header, which is where the match begins reading, so a UDP
# payload starts at 28 and a TCP one at 40 with the usual options.
tg_find() {
    local layer=$1 target=$2 proto=$3 kind=$4 pattern=$5 from=$6 to=$7
    shift 7
    local head=()
    [ "$proto" = any ] || head=(-p "$proto")
    tg_rule "$TORRENT_SCAN_CHAIN" "$layer" "$target" \
        ${head[@]+"${head[@]}"} "$@" \
        -m string "--${kind}" "$pattern" --algo bm --from "$from" --to "$to"
}

# multiport takes fifteen ports per rule and a range costs two of them, so a
# longer allowlist becomes several rules instead of being silently truncated.
torrent_port_chunks() {
    local chunk="" used=0 cost port
    for port in $(printf '%s' "${1:-}" | tr ',;' '  '); do
        case $port in *:*) cost=2 ;; *) cost=1 ;; esac
        if [ $((used + cost)) -gt 15 ]; then
            printf '%s\n' "$chunk"
            chunk=""
            used=0
        fi
        chunk="${chunk:+${chunk},}${port}"
        used=$((used + cost))
    done
    [ -z "$chunk" ] || printf '%s\n' "$chunk"
}

torrent_build_targets() {
    local chain
    for chain in "$TORRENT_HIT_CHAIN" "$TORRENT_CUT_CHAIN"; do
        iptables -t mangle -N "$chain" 2>/dev/null || iptables -t mangle -F "$chain" 2>/dev/null
    done

    if [ "$TORRENT_CAP_SET" = true ]; then
        # Remembering the peer is what carries the block across an encrypted
        # reconnection: the same address, whatever it speaks next time, is
        # already refused before anything looks at the payload.
        iptables -t mangle -A "$TORRENT_HIT_CHAIN" -j SET \
            --add-set "$TORRENT_PEER_SET" dst --exist 2>/dev/null || true
        iptables -t mangle -A "$TORRENT_HIT_CHAIN" -j SET \
            --add-set "$TORRENT_CLIENT_SET" src --exist 2>/dev/null || true
        iptables -t mangle -A "$TORRENT_CUT_CHAIN" -j SET \
            --add-set "$TORRENT_CLIENT_SET" src --exist 2>/dev/null || true
    fi

    # DROP rather than REJECT throughout. A refused connection sends a client to
    # the next peer in its list immediately; one that hangs costs it the whole
    # timeout, which is the difference between a swarm joined slowly and a swarm
    # not joined.
    iptables -t mangle -A "$TORRENT_HIT_CHAIN" -j DROP 2>/dev/null || true
    iptables -t mangle -A "$TORRENT_CUT_CHAIN" -j DROP 2>/dev/null || true
    return 0
}

# Peer discovery. None of this is encrypted in any client, because the two ends
# have nothing to derive a key from yet — which is why it is the layer that
# decides whether a swarm ever learns this node's address.
torrent_build_discovery() {
    local pattern

    # BEP 15: the UDP tracker protocol opens every session by sending the
    # constant 0x41727101980 as a 64-bit connection id. It is in the first
    # datagram of every announce and no client can omit it.
    tg_find tracker "$TORRENT_HIT_CHAIN" udp hex-string '|0000041727101980|' 28 40

    # BEP 5: KRPC over UDP, bencoded. A query names the sender's node id in a
    # fixed 12-byte preamble; the queries themselves are literal strings with
    # their own lengths in front of them.
    for pattern in 'd1:ad2:id20:' 'd1:rd2:id20:' '1:q4:ping' '9:find_node' '9:get_peers' '13:announce_peer'; do
        tg_find dht "$TORRENT_HIT_CHAIN" udp string "$pattern" 28 640
    done

    # BEP 3 and BEP 48 over HTTP. An announce is a query string, so it is
    # readable in the request line of an unencrypted tracker request.
    for pattern in 'info_hash=' 'peer_id=' '/announce?' '/scrape?' 'BitTorrent/' 'x-bittorrent'; do
        tg_find tracker "$TORRENT_HIT_CHAIN" tcp string "$pattern" 0 1500
    done

    # BEP 14: local service discovery. Multicast is not forwarded, so this only
    # ever matches a client that has been told to send it somewhere routable.
    tg_rule "$TORRENT_SCAN_CHAIN" lsd "$TORRENT_CUT_CHAIN" -p udp --dport 6771
    tg_find lsd "$TORRENT_CUT_CHAIN" udp string 'BT-SEARCH' 28 128

    # The DHT bootstrap nodes and the trackers a client falls back to when it has
    # nothing else. Matched in the DNS query rather than by address, because the
    # addresses move and the names do not.
    for pattern in 'bittorrent' 'utorrent' 'libtorrent' 'transmissionbt' 'bttracker' 'opentrackr' 'demonii' 'torrent.eu.org'; do
        tg_find dns "$TORRENT_CUT_CHAIN" udp string "$pattern" 28 640 --dport 53
        tg_find dns "$TORRENT_CUT_CHAIN" tcp string "$pattern" 0 640 --dport 53
    done
    # `torrent` and `tracker` on their own take a news site and an analytics host
    # with them, so they are only matched where that trade has been made.
    if [ "$TORRENT_MODE" = strict ]; then
        for pattern in 'torrent' 'tracker'; do
            tg_find dns "$TORRENT_CUT_CHAIN" udp string "$pattern" 28 640 --dport 53
            tg_find dns "$TORRENT_CUT_CHAIN" tcp string "$pattern" 0 640 --dport 53
        done
    fi
    return 0
}

# The peer wire. Everything here is either unencrypted or a fixed shape that MSE
# has not started covering yet.
torrent_build_wire() {
    local pattern

    # BEP 29: a uTP header is 20 bytes and its first byte is (type << 4) | 1. A
    # connection opens with ST_SYN — 0x41 — in a datagram that carries nothing
    # but that header, so the whole packet is 48 bytes. Matching it is matching
    # the only packet of a uTP connection that exists before MSE takes over,
    # which is why encrypted uTP dies here too.
    tg_rule "$TORRENT_SCAN_CHAIN" utp "$TORRENT_HIT_CHAIN" \
        -p udp -m length --length 48 \
        -m string --hex-string '|4100|' --algo bm --from 28 --to 30
    tg_rule "$TORRENT_SCAN_CHAIN" utp "$TORRENT_HIT_CHAIN" \
        -p udp -m length --length 48 \
        -m string --hex-string '|4101|' --algo bm --from 28 --to 30

    # BEP 3: the unencrypted peer handshake, which is a length-prefixed protocol
    # name — 0x13 "BitTorrent protocol".
    tg_find handshake "$TORRENT_HIT_CHAIN" tcp hex-string \
        '|13426974546f7272656e742070726f746f636f6c|' 0 120

    # BEP 9, 10 and 11: the extension handshake and the messages it carries.
    # These ride an already-open peer connection, so they are a second chance at
    # one whose opening was missed rather than the first line of anything.
    for pattern in 'ut_pex' 'ut_metadata' 'ut_holepunch' 'lt_donthave' 'metadata_size' 'upload_only'; do
        tg_find pex "$TORRENT_HIT_CHAIN" any string "$pattern" 0 1500
    done

    # The ports a client uses when nobody has told it otherwise. Nearly free, and
    # the only layer that costs nothing at all on a packet that matches nothing.
    tg_rule "$TORRENT_SCAN_CHAIN" port "$TORRENT_HIT_CHAIN" \
        -p tcp -m multiport --dports 6881:6889,6969,51413
    tg_rule "$TORRENT_SCAN_CHAIN" port "$TORRENT_HIT_CHAIN" \
        -p udp -m multiport --dports 6881:6889,6969,51413
    return 0
}

# Outbound TCP and UDP, refused except to the ports something answers on. Not a
# torrent signature at all — it is what closes the one path the signatures cannot
# see, which is MSE to an address the client already had.
torrent_build_strict() {
    local chunk
    while read -r chunk; do
        [ -n "$chunk" ] || continue
        tg_rule "$TORRENT_CHAIN" allow RETURN -p tcp -m multiport --dports "$chunk"
    done < <(torrent_port_chunks "$TORRENT_TCP_PORTS")
    tg_rule "$TORRENT_CHAIN" strict-tcp "$TORRENT_CUT_CHAIN" -p tcp

    while read -r chunk; do
        [ -n "$chunk" ] || continue
        tg_rule "$TORRENT_CHAIN" allow RETURN -p udp -m multiport --dports "$chunk"
    done < <(torrent_port_chunks "$TORRENT_UDP_PORTS")
    tg_rule "$TORRENT_CHAIN" strict-udp "$TORRENT_CUT_CHAIN" -p udp
    return 0
}

# The reply direction. Small on purpose: a peer cannot open a connection to a
# client behind this node's NAT, so the only inbound traffic worth looking at is
# the answer to a request the client made.
torrent_build_inbound() {
    iptables -t mangle -N "$TORRENT_IN_CHAIN" 2>/dev/null \
        || iptables -t mangle -F "$TORRENT_IN_CHAIN" 2>/dev/null

    if [ "$TORRENT_CAP_SET" = true ]; then
        tg_rule "$TORRENT_IN_CHAIN" peer DROP -m set --match-set "$TORRENT_PEER_SET" src
    fi
    [ "$TORRENT_CAP_STRING" = true ] || return 0

    local scan=()
    [ "$TORRENT_CAP_CONNBYTES" != true ] || scan=(
        -m connbytes --connbytes "0:${TORRENT_SCAN_PACKETS}"
        --connbytes-dir both --connbytes-mode packets
    )

    # A .torrent file is a bencoded dict that opens with its announce URL, and it
    # is served as its own content type. Dropping it stops a torrent before the
    # client has anything to join a swarm with — a bonus rather than a load
    # bearing layer, since a magnet link carries no file at all.
    tg_rule "$TORRENT_IN_CHAIN" metainfo DROP ${scan[@]+"${scan[@]}"} -p tcp \
        -m string --string 'application/x-bittorrent' --algo bm --from 0 --to 1500
    tg_rule "$TORRENT_IN_CHAIN" metainfo DROP ${scan[@]+"${scan[@]}"} -p tcp \
        -m string --string 'd8:announce' --algo bm --from 0 --to 200
    return 0
}

torrent_build() {
    local chain

    TORRENT_RULES=0
    TORRENT_REFUSED=0
    TORRENT_BUILD_ERROR=""
    for chain in "$TORRENT_CHAIN" "$TORRENT_SCAN_CHAIN"; do
        iptables -t mangle -N "$chain" 2>/dev/null || iptables -t mangle -F "$chain" 2>/dev/null
    done
    torrent_build_targets

    # Anything already known to speak the protocol, whatever it is speaking now.
    # Through the same target as a fresh catch so that a client which keeps
    # retrying a peer keeps the block on it alive.
    if [ "$TORRENT_CAP_SET" = true ]; then
        tg_rule "$TORRENT_CHAIN" peer "$TORRENT_HIT_CHAIN" -m set --match-set "$TORRENT_PEER_SET" dst
    fi

    if [ "$TORRENT_CAP_STRING" = true ]; then
        if [ "$TORRENT_CAP_CONNBYTES" = true ]; then
            tg_rule "$TORRENT_CHAIN" scan "$TORRENT_SCAN_CHAIN" \
                -m connbytes --connbytes "0:${TORRENT_SCAN_PACKETS}" \
                --connbytes-dir original --connbytes-mode packets
        else
            tg_rule "$TORRENT_CHAIN" scan "$TORRENT_SCAN_CHAIN"
        fi
        torrent_build_discovery
        torrent_build_wire
    else
        # No string match means no signature layer at all, so the ports are the
        # only thing left that names BitTorrent rather than everything else.
        tg_rule "$TORRENT_CHAIN" port "$TORRENT_HIT_CHAIN" \
            -p tcp -m multiport --dports 6881:6889,6969,51413
        tg_rule "$TORRENT_CHAIN" port "$TORRENT_HIT_CHAIN" \
            -p udp -m multiport --dports 6881:6889,6969,51413
        TORRENT_BUILD_ERROR="this kernel has no iptables string match, so only the port rules are in force"
        [ "$TORRENT_MODE" != strict ] \
            || TORRENT_BUILD_ERROR="${TORRENT_BUILD_ERROR} alongside the strict port policy"
    fi

    [ "$TORRENT_MODE" != strict ] || torrent_build_strict
    torrent_build_inbound

    # A rule refused for any other reason — a match the probe did not test for,
    # a kernel that has the module but not the revision this uses. Never enough
    # to stop, always enough to say.
    if [ "$TORRENT_REFUSED" -gt 0 ] && [ -z "$TORRENT_BUILD_ERROR" ]; then
        TORRENT_BUILD_ERROR="this kernel refused ${TORRENT_REFUSED} of the $((TORRENT_RULES + TORRENT_REFUSED)) rules, so the block is not complete"
    fi
    [ -z "$TORRENT_BUILD_ERROR" ] || log "torrents: $TORRENT_BUILD_ERROR"
    return 0
}

# ---------------------------------------------------------------------------
# Installing and withdrawing
# ---------------------------------------------------------------------------

torrent_hooked() {
    iptables -t mangle -C FORWARD -i "$AWG_IFACE" -j "$TORRENT_CHAIN" 2>/dev/null
}

torrent_hook_add() {
    torrent_hooked \
        || iptables -t mangle -A FORWARD -i "$AWG_IFACE" -j "$TORRENT_CHAIN" 2>/dev/null || true
    iptables -t mangle -C FORWARD -o "$AWG_IFACE" -j "$TORRENT_IN_CHAIN" 2>/dev/null \
        || iptables -t mangle -A FORWARD -o "$AWG_IFACE" -j "$TORRENT_IN_CHAIN" 2>/dev/null || true
}

torrent_hook_del() {
    iptables -t mangle -D FORWARD -i "$AWG_IFACE" -j "$TORRENT_CHAIN" 2>/dev/null || true
    iptables -t mangle -D FORWARD -o "$AWG_IFACE" -j "$TORRENT_IN_CHAIN" 2>/dev/null || true
}

torrent_teardown() {
    local chain
    torrent_hook_del
    for chain in "$TORRENT_CHAIN" "$TORRENT_SCAN_CHAIN" "$TORRENT_IN_CHAIN" \
                 "$TORRENT_HIT_CHAIN" "$TORRENT_CUT_CHAIN"; do
        iptables -t mangle -F "$chain" 2>/dev/null || true
    done
    # The targets are referenced by the chains above, so they can only go once
    # those are empty — which is why this is a second pass rather than one.
    for chain in "$TORRENT_CHAIN" "$TORRENT_SCAN_CHAIN" "$TORRENT_IN_CHAIN" \
                 "$TORRENT_HIT_CHAIN" "$TORRENT_CUT_CHAIN"; do
        iptables -t mangle -X "$chain" 2>/dev/null || true
    done
    if command -v ipset >/dev/null 2>&1; then
        ipset destroy "$TORRENT_PEER_SET" 2>/dev/null || true
        ipset destroy "$TORRENT_CLIENT_SET" 2>/dev/null || true
    fi
    # The sets went with the rules, so a later probe has to recreate them — and
    # everything it decided is dropped with them rather than kept, so that what
    # is published always describes the ladder that is actually installed.
    TORRENT_CAPS_PROBED=false
    TORRENT_CAP_STRING=false
    TORRENT_CAP_COMMENT=false
    TORRENT_CAP_CONNBYTES=false
    TORRENT_CAP_SET=false
    TORRENT_ACTIVE=false
    TORRENT_APPLIED=""
    TORRENT_RULES=0
    TORRENT_REFUSED=0
    TORRENT_BUILD_ERROR=""
}

# Brings what is installed into line with the mode in force. Idempotent and cheap
# when nothing changed, so it can be called from anywhere that might have changed
# something.
torrent_apply() {
    local want=$TORRENT_MODE was=$TORRENT_ACTIVE signature

    if [ "$want" = off ]; then
        if [ "$TORRENT_ACTIVE" = true ]; then
            torrent_teardown
            log "torrents: nothing is being blocked any more"
        fi
        return 0
    fi

    torrent_probe_caps

    # The signature covers everything that changes what is installed. The hook is
    # checked separately because a flush of the mangle table elsewhere would take
    # it without changing anything here.
    signature="${want}|${AWG_IFACE}|${TORRENT_TCP_PORTS}|${TORRENT_UDP_PORTS}|${TORRENT_SCAN_PACKETS}"
    if [ "$TORRENT_ACTIVE" = true ] && [ "$signature" = "$TORRENT_APPLIED" ] && torrent_hooked; then
        return 0
    fi

    torrent_build
    torrent_hook_add
    TORRENT_ACTIVE=true
    TORRENT_APPLIED=$signature

    if [ "$was" != true ]; then
        # A connection that was already open has no signature left to match: its
        # handshake is in the past and the rest is either encrypted or just data.
        # Dropping the tracking entries is what makes "on" mean now rather than
        # from the next connection onwards.
        conntrack -D -s "$AWG_SUBNET" >/dev/null 2>&1 || true
    fi
    log "torrents: blocking (${want}) with ${TORRENT_RULES} rule(s) on ${AWG_IFACE}"
    return 0
}

torrent_reload() {
    torrent_parse || true
    torrent_apply
}

# Worst first: a ladder nothing is walking through is a bigger problem than a
# ladder with a rung missing, which is a bigger problem than a file with a typo
# in it that has already been fallen back from.
torrent_error() {
    if [ "$TORRENT_MODE" != off ] && [ "$TORRENT_ACTIVE" = true ] && ! torrent_hooked; then
        printf 'the torrent rules are installed but nothing is being sent through them'
    elif [ -n "$TORRENT_ERROR" ]; then
        printf '%s' "$TORRENT_ERROR"
    elif [ "$TORRENT_ACTIVE" = true ]; then
        printf '%s' "$TORRENT_BUILD_ERROR"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# What it caught
# ---------------------------------------------------------------------------

# Per-layer packet counters, straight off the rules. The comment on each rule is
# what ties several rules of one layer together, so this reports "dht" once
# rather than the six bencode strings that make it up.
torrent_counters_json() {
    local rows
    rows=$(iptables-save -c -t mangle 2>/dev/null | awk '
        match($0, /saucewg:torrent:[a-z-]+/) {
            layer = substr($0, RSTART + 16, RLENGTH - 16)
            counter = $1
            gsub(/[][]/, "", counter)
            split(counter, n, ":")
            packets[layer] += n[1]
        }
        END { for (l in packets) printf "%s\t%d\n", l, packets[l] }') || rows=""

    printf '%s\n' "$rows" | jq -R -s '
        split("\n") | map(select(length > 0) | split("\t"))
        | map({key: .[0], value: (.[1] | tonumber)})
        | from_entries
        # `allow` and `scan` are the rules traffic passes through rather than
        # dies on, so counting them in the total would report the whole node.
        | . + {total: ([to_entries[] | select(.key != "allow" and .key != "scan") | .value] | add // 0)}
    ' 2>/dev/null || printf '{"total":0}'
}

torrent_peer_count() {
    [ "$TORRENT_CAP_SET" = true ] || { printf '0'; return; }
    # -t prints the header alone: the set holds a quarter of a million addresses
    # at its ceiling and only the size is wanted here.
    ipset list -t "$TORRENT_PEER_SET" 2>/dev/null \
        | sed -n 's/^Number of entries: *//p' | head -n1 | tr -cd '0-9' \
        | grep . || printf '0'
}

# The client addresses that tripped the guard, and what it cost them. This is the
# answer to "who is torrenting", which is the question an operator actually has —
# the panel joins these to client names.
torrent_clients_json() {
    [ "$TORRENT_CAP_SET" = true ] || { printf '[]'; return; }
    ipset list "$TORRENT_CLIENT_SET" 2>/dev/null | awk '
        /^Members:/ { members = 1; next }
        members && NF {
            packets = 0; timeout = 0
            for (i = 2; i < NF; i++) {
                if ($i == "packets") packets = $(i + 1)
                else if ($i == "timeout") timeout = $(i + 1)
            }
            printf "%s\t%d\t%d\n", $1, packets, timeout
        }' \
        | sort -t$'\t' -k2 -rn | head -n 50 \
        | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {
              address: .[0], packets: (.[1] | tonumber), expires_in: (.[2] | tonumber)
          })' 2>/dev/null || printf '[]'
}

torrent_state_json() {
    jq -n \
        --arg mode "$TORRENT_MODE" \
        --arg source "$TORRENT_SOURCE" \
        --arg error "$(torrent_error)" \
        --arg iface "$AWG_IFACE" \
        --argjson active "$([ "$TORRENT_ACTIVE" = true ] && echo true || echo false)" \
        --argjson rules "${TORRENT_RULES:-0}" \
        --argjson blocked "$(torrent_counters_json)" \
        --argjson peers "$(torrent_peer_count)" \
        --argjson clients "$(torrent_clients_json)" \
        --argjson caps "$(jq -n \
            --argjson string "$([ "$TORRENT_CAP_STRING" = true ] && echo true || echo false)" \
            --argjson ipset "$([ "$TORRENT_CAP_SET" = true ] && echo true || echo false)" \
            --argjson connbytes "$([ "$TORRENT_CAP_CONNBYTES" = true ] && echo true || echo false)" \
            --argjson comment "$([ "$TORRENT_CAP_COMMENT" = true ] && echo true || echo false)" \
            '{string: $string, ipset: $ipset, connbytes: $connbytes, comment: $comment}')" \
        --argjson now "$(date -u +%s)" \
        '{
            updated_at: $now,
            mode: $mode,
            source: $source,
            iface: $iface,
            active: $active,
            rules: $rules,
            capabilities: $caps,
            blocked: $blocked,
            peers: $peers,
            clients: $clients,
            error: (if $error == "" then null else $error end)
        }' 2>/dev/null || printf 'null'
}

# Published in its own file rather than folded into uplinks.json, because this
# runs on an exit node too — where there is no cascade and no uplink state.
#
# Never fatal: a state file that cannot be written costs the panel a page, and
# this is called from the monitor loop that keeps the node's traffic moving.
torrent_write_state() {
    local tmp="${TORRENT_STATE_FILE}.tmp"
    mkdir -p "$(dirname "$TORRENT_STATE_FILE")" 2>/dev/null || true
    if torrent_state_json > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$TORRENT_STATE_FILE"
        chmod 0644 "$TORRENT_STATE_FILE"
    else
        rm -f "$tmp"
        log "torrents: could not write ${TORRENT_STATE_FILE}"
    fi
    return 0
}

# The whole cycle, for a caller that has no monitor of its own to hang it off.
torrent_tick() {
    torrent_reload
    torrent_write_state
}
