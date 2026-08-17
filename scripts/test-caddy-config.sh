#!/usr/bin/env bash
# Checks that the web container accepts every CADDY_AUTO_HTTPS the rest of the tree writes.
#
#   ./scripts/test-caddy-config.sh
#
# The Caddyfile is adapted when the container starts, not when the image is built, so a
# value the global options block will not take is not a warning in a log — it is `caddy
# run` exiting before it binds a port, on a restart policy, forever. Nothing else notices:
# the panel and the database stay healthy and the installer still prints a URL. That is
# how `--domain` shipped writing `auto_https on`, which Caddy has never had.
#
# So every value the installer and the documentation can produce is adapted here against
# the real caddy image, and the resulting JSON is checked to be the config that was meant.
#
# Needs bash 4+, docker and jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=saucewg-caddy-config-test

PASSED=0
FAILED=0

check() {
    local what=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        printf '  ok   %s\n' "$what"
        PASSED=$((PASSED + 1))
    else
        printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$what" "$want" "$got"
        FAILED=$((FAILED + 1))
    fi
}

# The frontend bundle is irrelevant to config adaptation, so only the final stage of
# docker/caddy/Dockerfile is reproduced here — that keeps the check to a few seconds.
build() {
    local base
    base=$(sed -n 's/^FROM \(caddy:[^ ]*\).*/\1/p' "$ROOT/docker/caddy/Dockerfile" | head -1)
    [ -n "$base" ] || { echo "could not find the caddy base image in the Dockerfile" >&2; exit 1; }
    printf 'using %s\n\n' "$base"
    docker build -q -t "$IMAGE" -f - "$ROOT/docker/caddy" >/dev/null <<EOF
FROM ${base}
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /srv/panel && chmod +x /usr/local/bin/entrypoint.sh \
 && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
EOF
}

adapt() {
    local auto_https=$1 site=$2
    docker run --rm -e CADDY_AUTO_HTTPS="$auto_https" -e PANEL_SITE_ADDRESS="$site" \
        "$IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null
}

# The value has to survive the round trip the installer actually performs, so it is
# read back out of the adapted JSON rather than out of the Caddyfile.
srv() {
    jq -c --arg path "$2" '.apps.http.servers.srv0 | getpath($path | split(".")) // "unset"' <<<"$1"
}

# --- the image builds, which means the Caddyfile adapts with nothing set ---------
echo "the Caddyfile the image ships with"
build
check "it adapts with no environment at all (caddy validate, at build time)" ok ok

# --- what the installer writes ---------------------------------------------------
# saucewg.sh picks the value from one of two branches on --domain. Both are read
# out of the script so a third branch cannot be added without landing here.
echo
echo "every CADDY_AUTO_HTTPS saucewg.sh can write"
mapfile -t installer_values < <(sed -n 's/^ *\(local .*\)\?auto_https=\([a-z_]*\).*/\2/p' \
    "$ROOT/saucewg.sh" | sort -u)
check "saucewg.sh writes the two values --domain chooses between" "off on" "${installer_values[*]}"

for value in "${installer_values[@]}"; do
    if adapted=$(adapt "$value" "panel.example.com"); then
        check "CADDY_AUTO_HTTPS=${value} adapts" ok ok
    else
        check "CADDY_AUTO_HTTPS=${value} adapts" ok "caddy rejected it"
        continue
    fi
    case "$value" in
        on)  check "  ${value} serves TLS on :443" '[":443"]' "$(srv "$adapted" listen)"
             check "  ${value} leaves automatic HTTPS alone" '"unset"' "$(srv "$adapted" automatic_https)" ;;
        off) check "  ${value} disables automatic HTTPS" 'true' "$(srv "$adapted" automatic_https.disable)" ;;
    esac
done

# --- what .env.example and the documentation offer -------------------------------
echo
echo "every CADDY_AUTO_HTTPS the documentation offers"
for value in on off ON Off true false yes no 1 0 disable_redirects disable_certs \
             ignore_loaded_certs prefer_wildcard; do
    adapt "$value" "panel.example.com" >/dev/null \
        && check "CADDY_AUTO_HTTPS=${value} is accepted" ok ok \
        || check "CADDY_AUTO_HTTPS=${value} is accepted" ok "caddy rejected it"
done

# An empty value reaches the container whenever .env has the key with nothing after
# it, which is what a half-finished edit leaves behind.
check "an empty CADDY_AUTO_HTTPS falls back to plain HTTP" 'true' \
    "$(srv "$(adapt '' ':80')" automatic_https.disable)"

# --- the plain HTTP default ------------------------------------------------------
echo
echo "the default site address"
default=$(adapt off ':80')
check "no domain listens on :80" '[":80"]' "$(srv "$default" listen)"
check "no domain asks for no certificate" 'true' "$(srv "$default" automatic_https.disable)"

# --- a typo is a message, not a parse error --------------------------------------
echo
echo "a value that is neither"
if out=$(docker run --rm -e CADDY_AUTO_HTTPS=enabled-please -e PANEL_SITE_ADDRESS=:80 \
         "$IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
    check "a misspelt value stops the container" "refused" "started anyway"
else
    check "a misspelt value stops the container" "refused" "refused"
    grep -q 'CADDY_AUTO_HTTPS' <<<"$out" \
        && check "  it says which variable is wrong" ok ok \
        || check "  it says which variable is wrong" ok "$(head -1 <<<"$out")"
fi

docker image rm -f "$IMAGE" >/dev/null 2>&1 || true

echo
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
