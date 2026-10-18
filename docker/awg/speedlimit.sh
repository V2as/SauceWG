#!/usr/bin/env bash
# One ceiling on how fast any client can move data through this entry node.
#
# The setting is a single number, applied to every client separately and to each
# direction separately: at 50 Mbit/s every client can download at up to 50 and
# upload at up to 50, however many of the others are doing the same. It is a cap
# on each client, not a share of the server — ten clients at the limit are 500
# Mbit/s, and the server's own link is still the ceiling above that.
#
# It is built on the hashlimit match rather than on tc. hashlimit keeps a token
# bucket per address and creates it on the first packet that address sends, so one
# rule per direction covers every client on the subnet — including one the panel
# created a second ago — with nothing to reconcile against the peer list and
# nothing to clean up when a client is deleted. A tc shaper needs a class per
# client kept in step with the panel, plus an ifb device before it can shape what
# clients send at all, which is a lot of moving parts for one number.
#
# What that buys is a policer rather than a shaper: a packet over the limit is
# dropped instead of queued. TCP reads the drop as congestion and settles at the
# limit, which is what a speed test sees. The bucket holds one second at the
# limit, so a client that has been idle sends its first second at full speed, and
# the average over anything longer is the limit.
#
# The rules hang off mangle/PREROUTING for what clients send and mangle/POSTROUTING
# for what they receive. Both see every packet on the client interface whichever
# way it goes — to an exit node, out of this node's own interface, or into the
# bypass relay, which is local delivery and would never be seen on the forwarding
# path. The tunnel itself is never throttled: handshakes and keepalives travel
# encrypted outside the client interface, so a client at its limit stays connected.
#
# Entry node only. On an exit node every client arrives as one address, the entry
# node's end of an uplink, so there is nothing per client to limit by. IPv4 only,
# because the client interface is.

SPEED_LIMIT=${SPEED_LIMIT:-}
SPEED_LIMIT_FILE=${SPEED_LIMIT_FILE:-/etc/amnezia/host/speed-limit.json}
SPEED_LIMIT_STATE_FILE=${SPEED_LIMIT_STATE_FILE:-/var/run/amneziawg/speed-limit.json}

# The range a rate has to be in, in kbit/s. Below 0.1 Mbit/s a bucket holds about
# eight full-size packets and nothing interactive survives it; above 10 Gbit/s the
# kernel's byte accounting rounds by more than a few percent, and no userspace
# tunnel moves that much anyway.
SPEED_MIN_KBIT=100
SPEED_MAX_KBIT=10000000

SPEED_UP_CHAIN=SAUCEWG_LIMIT_UP
SPEED_DOWN_CHAIN=SAUCEWG_LIMIT_DOWN

# The rate in force in kbit/s — 0 for none — and where that was decided. Whole
# kbit/s because bash has no decimals and hashlimit wants bytes: one kbit/s is
# exactly 125 bytes a second.
SPEED_KBIT=0
SPEED_SOURCE=none
# What is wrong with the setting, and separately what was wrong with installing it,
# kept apart for the same reason the torrent guard keeps them apart: a bad file is
# fixed by editing it, a missing kernel module is not.
SPEED_ERROR=""
SPEED_BUILD_ERROR=""
# What is installed: whether anything is, which directions, and the setting it was
# built for. "unknown" until the first apply, so that the first one with nothing to
# enforce still clears what a container killed rather than stopped left behind in
# the host's tables.
SPEED_ACTIVE=false
SPEED_DIRS=""
SPEED_APPLIED=unknown
SPEED_RULES=0

SPEED_CAPS_PROBED=false
SPEED_CAP_HASHLIMIT=false
SPEED_CAP_COMMENT=false
# Whether `iptables -C` recognises a rule this installed. It compares match data
# byte for byte, and an iptables build that got that wrong for hashlimit would make
# every tick look like a flush — rebuilding the rules and handing every client a
# fresh bucket, a free second, each time. Found out once, right after the rules go
# in, and the hooks alone are checked from then on.
SPEED_CHECK_RULES=true

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

speed_is_off() {
    case $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]') in
        off|0|no|false|disabled|none) return 0 ;;
        *) return 1 ;;
    esac
}

# A rate in Mbit/s as an operator writes it — 50, 7.5, 0.25, or 50mbit — as whole
# kbit/s, or failure for anything that is not a number in range. "mb" on its own is
# refused rather than guessed at: half the people who write it mean megabytes. So
# is MBps, which is megabytes and differs from Mbps only in the case of the B.
speed_kbit() {
    local value
    value=$(printf '%s' "${1:-}" | tr -d '[:space:]')
    case $value in *B[pP][sS]) return 1 ;; esac
    printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]' \
        | awk -v min="$SPEED_MIN_KBIT" -v max="$SPEED_MAX_KBIT" '
            {
                sub(/(mbit\/s|mbit|mbps)$/, "")
                if ($0 !~ /^[0-9]+([.][0-9]+)?$/) exit 1
                kbit = int($0 * 1000 + 0.5)
                if (kbit < min || kbit > max) exit 1
                print kbit
                ok = 1
            }
            END { exit ok ? 0 : 1 }'
}

# kbit/s back to Mbit/s, exactly: 7500 is 7.5 and 100 is 0.1, and the result is a
# valid JSON number.
speed_mbit() {
    local kbit=${1:-0} frac
    frac=$(printf '%03d' $((kbit % 1000)))
    frac=${frac%0}
    frac=${frac%0}
    frac=${frac%0}
    printf '%s%s' $((kbit / 1000)) "${frac:+.${frac}}"
}

speed_config_source() {
    if [ -n "${SPEED_LIMIT:-}" ]; then
        printf 'env'
    elif [ -f "$SPEED_LIMIT_FILE" ]; then
        printf 'file'
    else
        printf 'none'
    fi
}

# The file the panel writes: {"enabled": true, "rate_mbit": 50}. The switch and the
# rate are kept apart, as the torrent guard keeps its switch and its mode, so that
# lifting the limit and putting it back does not lose the number.
#
# A file that cannot be used leaves what is in force alone rather than lifting the
# limit: a typo in a hand edit should not hand every client the whole server.
speed_parse() {
    local raw enabled rate kbit

    SPEED_SOURCE=$(speed_config_source)
    SPEED_ERROR=""
    # Reading the setting again is also how an operator asks for another try —
    # after loading xt_hashlimit on the host, say — so a build that went wrong is
    # not remembered past it.
    if [ -n "$SPEED_BUILD_ERROR" ]; then
        SPEED_CAPS_PROBED=false
        SPEED_APPLIED=unknown
    fi

    case $SPEED_SOURCE in
        env)
            if speed_is_off "$SPEED_LIMIT"; then
                kbit=0
            elif ! kbit=$(speed_kbit "$SPEED_LIMIT"); then
                SPEED_ERROR="SPEED_LIMIT=${SPEED_LIMIT} is neither off nor a rate between 0.1 and 10000 Mbit/s, so nothing is limited"
                log "speed limit: $SPEED_ERROR"
                kbit=0
            fi
            ;;
        file)
            raw=$(cat "$SPEED_LIMIT_FILE" 2>/dev/null) || raw=""
            if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
                SPEED_ERROR="${SPEED_LIMIT_FILE} is not a JSON object; keeping the limit that is already in force"
                log "speed limit: $SPEED_ERROR"
                return 1
            fi
            enabled=$(printf '%s' "$raw" | jq -r 'if has("enabled") then (.enabled | tostring) else "true" end')
            rate=$(printf '%s' "$raw" | jq -r 'if .rate_mbit == null then "" else (.rate_mbit | tostring) end')
            if [ "$enabled" != true ]; then
                kbit=0
            elif [ -z "$rate" ]; then
                SPEED_ERROR="${SPEED_LIMIT_FILE} turns the limit on but names no rate_mbit; keeping the limit that is already in force"
                log "speed limit: $SPEED_ERROR"
                return 1
            elif ! kbit=$(speed_kbit "$rate"); then
                SPEED_ERROR="'${rate}' is not a rate between 0.1 and 10000 Mbit/s; keeping the limit that is already in force"
                log "speed limit: $SPEED_ERROR"
                return 1
            fi
            ;;
        *) kbit=0 ;;
    esac

    SPEED_KBIT=$kbit
    return 0
}

speed_config_mtime() {
    [ -f "$SPEED_LIMIT_FILE" ] || { printf '0'; return; }
    stat -c %Y "$SPEED_LIMIT_FILE" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# What the kernel can match
# ---------------------------------------------------------------------------

speed_try_match() {
    iptables -t mangle -A "${SPEED_UP_CHAIN}_PROBE" "$@" -j RETURN 2>/dev/null
}

speed_probe_caps() {
    [ "$SPEED_CAPS_PROBED" = true ] && return 0
    SPEED_CAPS_PROBED=true
    SPEED_CAP_HASHLIMIT=false
    SPEED_CAP_COMMENT=false

    iptables -t mangle -N "${SPEED_UP_CHAIN}_PROBE" 2>/dev/null \
        || iptables -t mangle -F "${SPEED_UP_CHAIN}_PROBE" 2>/dev/null || return 0

    # A byte rate rather than a packet rate, because that is the half of hashlimit
    # this needs and the half a kernel old enough to have only the other lacks.
    speed_try_match -m hashlimit --hashlimit-above 125000b/s --hashlimit-mode srcip \
            --hashlimit-name sw-probe \
        && SPEED_CAP_HASHLIMIT=true
    speed_try_match -m comment --comment saucewg-probe \
        && SPEED_CAP_COMMENT=true

    iptables -t mangle -F "${SPEED_UP_CHAIN}_PROBE" 2>/dev/null || true
    iptables -t mangle -X "${SPEED_UP_CHAIN}_PROBE" 2>/dev/null || true

    log "speed limit: kernel matches — hashlimit=${SPEED_CAP_HASHLIMIT} comment=${SPEED_CAP_COMMENT}"
    return 0
}

# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------

speed_chain() {
    if [ "$1" = up ]; then
        printf '%s' "$SPEED_UP_CHAIN"
    else
        printf '%s' "$SPEED_DOWN_CHAIN"
    fi
}

# How many clients a bucket table has to be able to hold: every address on the
# subnet. A full table does not let a newcomer through unlimited, it drops the
# newcomer's packets outright.
speed_table_max() {
    local prefix=${AWG_SUBNET##*/}
    case $prefix in ''|*[!0-9]*) prefix=24 ;; esac
    [ "$prefix" -le 24 ] || prefix=24
    [ "$prefix" -ge 12 ] || prefix=12
    printf '%s' $((1 << (32 - prefix)))
}

# The one rule of a direction, as words in SPEED_RULE, so that installing it and
# checking it is still there cannot drift apart. A client is its source address on
# the way in and its destination on the way out.
#
# The rate is in the table's name because the kernel keeps tables by name: a rule
# added under a name still alive — and with iptables-nft the old rule is released
# after the new one arrives — joins the old table and keeps the old rate. The name
# has to fit in 15 characters for the oldest revision of the match, which
# "sw-dn-10000000" does.
speed_rule_words() {
    local dir=$1 key=srcip short=up
    if [ "$dir" != up ]; then
        key=dstip
        short=dn
    fi
    SPEED_RULE=(
        -m hashlimit
        --hashlimit-above "$((SPEED_KBIT * 125))b/s"
        --hashlimit-mode "$key"
        --hashlimit-name "sw-${short}-${SPEED_KBIT}"
        --hashlimit-htable-max "$(speed_table_max)"
    )
    [ "$SPEED_CAP_COMMENT" != true ] || SPEED_RULE+=(-m comment --comment "saucewg:limit:${dir}")
    SPEED_RULE+=(-j DROP)
}

speed_hooked() {
    iptables -t mangle -C PREROUTING -i "$AWG_IFACE" -s "$AWG_SUBNET" -j "$SPEED_UP_CHAIN" 2>/dev/null \
        && iptables -t mangle -C POSTROUTING -o "$AWG_IFACE" -d "$AWG_SUBNET" -j "$SPEED_DOWN_CHAIN" 2>/dev/null
}

# First in each chain, so that nothing another rule accepts early gets past the
# limit.
speed_hook_add() {
    iptables -t mangle -C PREROUTING -i "$AWG_IFACE" -s "$AWG_SUBNET" -j "$SPEED_UP_CHAIN" 2>/dev/null \
        || iptables -t mangle -I PREROUTING 1 -i "$AWG_IFACE" -s "$AWG_SUBNET" -j "$SPEED_UP_CHAIN" 2>/dev/null \
        || true
    iptables -t mangle -C POSTROUTING -o "$AWG_IFACE" -d "$AWG_SUBNET" -j "$SPEED_DOWN_CHAIN" 2>/dev/null \
        || iptables -t mangle -I POSTROUTING 1 -o "$AWG_IFACE" -d "$AWG_SUBNET" -j "$SPEED_DOWN_CHAIN" 2>/dev/null \
        || true
}

speed_hook_del() {
    iptables -t mangle -D PREROUTING -i "$AWG_IFACE" -s "$AWG_SUBNET" -j "$SPEED_UP_CHAIN" 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -o "$AWG_IFACE" -d "$AWG_SUBNET" -j "$SPEED_DOWN_CHAIN" 2>/dev/null || true
}

speed_rules_present() {
    local dir
    for dir in $SPEED_DIRS; do
        speed_rule_words "$dir"
        iptables -t mangle -C "$(speed_chain "$dir")" "${SPEED_RULE[@]}" 2>/dev/null || return 1
    done
    return 0
}

# Hooked, and still holding the rules it was built with. Checked on every tick,
# because a flush of the mangle table by anything else on the host takes the limit
# with it and says nothing.
speed_intact() {
    speed_hooked || return 1
    [ "$SPEED_CHECK_RULES" != true ] || speed_rules_present
}

speed_uninstall() {
    local chain
    speed_hook_del
    for chain in "$SPEED_UP_CHAIN" "$SPEED_DOWN_CHAIN"; do
        iptables -t mangle -F "$chain" 2>/dev/null || true
        iptables -t mangle -X "$chain" 2>/dev/null || true
    done
}

speed_teardown() {
    speed_uninstall
    # The kernel is asked again next time rather than remembered, so that one which
    # gained xt_hashlimit since is found out by turning the limit off and on.
    SPEED_CAPS_PROBED=false
    SPEED_CAP_HASHLIMIT=false
    SPEED_CAP_COMMENT=false
    SPEED_CHECK_RULES=true
    SPEED_ACTIVE=false
    SPEED_DIRS=""
    SPEED_APPLIED=""
    SPEED_RULES=0
    SPEED_BUILD_ERROR=""
}

# A rule the kernel refuses is reported, never fatal: a limit on one direction is
# still a limit, and a container that will not start over a missing module limits
# nobody and carries nobody either.
speed_build() {
    local dir chain

    SPEED_RULES=0
    SPEED_DIRS=""
    SPEED_BUILD_ERROR=""
    SPEED_ACTIVE=false

    if [ "$SPEED_CAP_HASHLIMIT" != true ]; then
        speed_uninstall
        SPEED_BUILD_ERROR="this kernel has no iptables hashlimit match (xt_hashlimit), so nothing is limited"
        return 0
    fi

    for dir in up down; do
        chain=$(speed_chain "$dir")
        iptables -t mangle -N "$chain" 2>/dev/null || iptables -t mangle -F "$chain" 2>/dev/null || true
        speed_rule_words "$dir"
        if iptables -t mangle -A "$chain" "${SPEED_RULE[@]}" 2>/dev/null; then
            SPEED_RULES=$((SPEED_RULES + 1))
            SPEED_DIRS="${SPEED_DIRS:+${SPEED_DIRS} }${dir}"
        fi
    done

    case $SPEED_DIRS in
        "up down") ;;
        up) SPEED_BUILD_ERROR="this kernel refused the download rule, so only uploads are limited" ;;
        down) SPEED_BUILD_ERROR="this kernel refused the upload rule, so only downloads are limited" ;;
        *) SPEED_BUILD_ERROR="this kernel refused both hashlimit rules, so nothing is limited" ;;
    esac

    if [ -z "$SPEED_DIRS" ]; then
        speed_uninstall
        return 0
    fi
    speed_hook_add
    SPEED_ACTIVE=true
    SPEED_CHECK_RULES=true
    speed_rules_present || SPEED_CHECK_RULES=false
    return 0
}

# Brings what is installed into line with the rate in force. Idempotent and cheap
# when nothing changed, so it can be called from anywhere that might have changed
# something.
speed_apply() {
    local signature="${SPEED_KBIT}|${AWG_IFACE}|${AWG_SUBNET}"

    if [ "$SPEED_KBIT" -le 0 ]; then
        if [ -n "$SPEED_APPLIED" ]; then
            [ "$SPEED_ACTIVE" != true ] || log "speed limit: lifted, clients are no longer limited"
            speed_teardown
        fi
        return 0
    fi

    if [ "$signature" = "$SPEED_APPLIED" ]; then
        # Built for this setting already. What the kernel refused is not asked for
        # again until the setting is read again — retrying on every tick would
        # reset the buckets of the direction that did go in — and what it accepted
        # is checked for still being there.
        [ "$SPEED_ACTIVE" = true ] || return 0
        speed_intact && return 0
        log "speed limit: the rules went missing; putting them back"
    fi

    speed_probe_caps
    speed_build
    SPEED_APPLIED=$signature
    if [ "$SPEED_ACTIVE" = true ]; then
        log "speed limit: $(speed_mbit "$SPEED_KBIT") Mbit/s per client, each way, on ${AWG_IFACE}"
    fi
    [ -z "$SPEED_BUILD_ERROR" ] || log "speed limit: $SPEED_BUILD_ERROR"
    return 0
}

speed_reload() {
    speed_parse || true
    speed_apply
}

# Worst first: a limit nothing is walking through, then a setting that could not
# be read, then what the kernel would not do.
speed_error() {
    if [ "$SPEED_KBIT" -gt 0 ] && [ "$SPEED_ACTIVE" = true ] && ! speed_hooked; then
        printf 'the speed limit rules are installed but nothing is being sent through them'
    elif [ -n "$SPEED_ERROR" ]; then
        printf '%s' "$SPEED_ERROR"
    elif [ "$SPEED_KBIT" -gt 0 ]; then
        printf '%s' "$SPEED_BUILD_ERROR"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# What it is doing
# ---------------------------------------------------------------------------

# Packets dropped for being over the limit, per direction, straight off the rules.
# A rule is told apart by its table's name rather than by its comment, so this
# still counts on a kernel without the comment match. The counters start again
# whenever the rules are rebuilt — a new rate, or a restart.
speed_counters_json() {
    local rows up=0 down=0
    rows=$(iptables-save -c -t mangle 2>/dev/null | awk '
        /--hashlimit-name sw-(up|dn)-/ {
            counter = $1
            gsub(/[][]/, "", counter)
            split(counter, n, ":")
            if ($0 ~ /--hashlimit-name sw-up-/) { up += n[1] } else { down += n[1] }
        }
        END { printf "%d %d\n", up, down }') || rows=""
    read -r up down <<<"${rows:-0 0}" || true
    jq -n --argjson up "${up:-0}" --argjson down "${down:-0}" \
        '{up: $up, down: $down, total: ($up + $down)}' 2>/dev/null \
        || printf '{"up":0,"down":0,"total":0}'
}

speed_state_json() {
    local rate=null caps=null
    [ "$SPEED_KBIT" -le 0 ] || rate=$(speed_mbit "$SPEED_KBIT")
    # The kernel is only asked once there is a rate to install, so until then there
    # is no answer to publish — and false would read as a kernel that said no.
    if [ "$SPEED_CAPS_PROBED" = true ]; then
        caps=$(jq -n \
            --argjson hashlimit "$([ "$SPEED_CAP_HASHLIMIT" = true ] && echo true || echo false)" \
            --argjson comment "$([ "$SPEED_CAP_COMMENT" = true ] && echo true || echo false)" \
            '{hashlimit: $hashlimit, comment: $comment}')
    fi
    jq -n \
        --arg source "$SPEED_SOURCE" \
        --arg error "$(speed_error)" \
        --arg iface "$AWG_IFACE" \
        --argjson rate "$rate" \
        --argjson active "$([ "$SPEED_ACTIVE" = true ] && echo true || echo false)" \
        --argjson rules "${SPEED_RULES:-0}" \
        --argjson dropped "$(speed_counters_json)" \
        --argjson caps "$caps" \
        --argjson now "$(date -u +%s)" \
        '{
            updated_at: $now,
            rate_mbit: $rate,
            source: $source,
            iface: $iface,
            active: $active,
            rules: $rules,
            capabilities: $caps,
            dropped: $dropped,
            error: (if $error == "" then null else $error end)
        }' 2>/dev/null || printf 'null'
}

# Never fatal, for the same reason as the torrent guard's: a state file that cannot
# be written costs the panel a page, and this is called from the loop that keeps
# the node's traffic moving.
speed_write_state() {
    local tmp="${SPEED_LIMIT_STATE_FILE}.tmp"
    mkdir -p "$(dirname "$SPEED_LIMIT_STATE_FILE")" 2>/dev/null || true
    if speed_state_json > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
        && mv "$tmp" "$SPEED_LIMIT_STATE_FILE" 2>/dev/null; then
        chmod 0644 "$SPEED_LIMIT_STATE_FILE" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
        log "speed limit: could not write ${SPEED_LIMIT_STATE_FILE}"
    fi
    return 0
}

# The whole cycle, for a caller that has no monitor of its own to hang it off.
speed_tick() {
    speed_reload
    speed_write_state
}
