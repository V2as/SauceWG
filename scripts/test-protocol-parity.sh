#!/usr/bin/env bash
# Checks that the three places which define an AmneziaWG generation still agree.
#
#   ./scripts/test-protocol-parity.sh
#
# The node container decides which parameters an interface carries (docker/awg/lib.sh),
# the panel renders the client profile that has to match it (backend/app/awg/protocol.py),
# and the installer writes the .env both read (saucewg.sh). A disagreement between any
# two of them is a tunnel that comes up and never handshakes, or a config a router
# silently refuses — neither of which shows up as an error anywhere.
#
# Needs bash 4+, python3 and jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

# --- the node container ----------------------------------------------------
lib_report() {
    (
        # lib.sh calls die() on bad input; the harness only feeds it good input.
        # shellcheck source=../docker/awg/lib.sh
        . "$ROOT/docker/awg/lib.sh"
        printf 'suffixes\t%s\n' "$AWG_OBF_SUFFIXES"
        printf 'presets\t%s\n' "$AWG_CPS_PRESETS"
        local v
        for v in 1.0 1.5 2.0; do
            printf 'params.%s\t%s\n' "$v" "$(awg_protocol_params "$v")"
        done
        for v in legacy 1 1.0 1.5 2 2.0; do
            printf 'alias.%s\t%s\n' "$v" "$(awg_protocol "$v")"
        done
        for v in $AWG_CPS_PRESETS; do
            printf 'preset.%s\t%s\n' "$v" "$(awg_cps_preset "$v")"
        done
    )
}

# --- the installer --------------------------------------------------------
cli_report() {
    (
        # Everything but the final `main "$@"`, so the helpers can be called directly.
        # shellcheck disable=SC1090
        . <(sed '/^main "\$@"$/d' "$ROOT/saucewg.sh")
        printf 'suffixes\t%s\n' "$AWG_OBF_PARAMS"
        printf 'presets\t%s\n' "$AWG_CPS_PRESETS"
        local v
        for v in 1.0 1.5 2.0; do
            printf 'params.%s\t%s\n' "$v" "$(awg_protocol_params "$v")"
        done
        for v in legacy 1 1.0 1.5 2 2.0; do
            printf 'alias.%s\t%s\n' "$v" "$(awg_protocol "$v")"
        done
        for v in $AWG_CPS_PRESETS; do
            printf 'preset.%s\t%s\n' "$v" "$(awg_cps_preset "$v")"
        done
    )
}

# --- the panel ------------------------------------------------------------
# Loaded from its file rather than as app.awg.protocol: the package __init__ opens a
# UAPI client and pulls in pydantic, and the generation table needs neither.
load_panel_module='
import importlib.util, os
path = os.path.join(os.environ["ROOT"], "backend", "app", "awg", "protocol.py")
spec = importlib.util.spec_from_file_location("awg_protocol", path)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
'

panel_report() {
    ROOT="$ROOT" python3 - <<PY
${load_panel_module}
print("suffixes\t" + " ".join(p.ALL_PARAMS))
print("presets\t" + " ".join(p.CPS_PRESETS))
for v in ("1.0", "1.5", "2.0"):
    print(f"params.{v}\t" + " ".join(p.PROTOCOL_PARAMS[v]))
for v in ("legacy", "1", "1.0", "1.5", "2", "2.0"):
    print(f"alias.{v}\t" + p.normalize(v))
for name, spec in p.CPS_PRESETS.items():
    print(f"preset.{name}\t{spec}")
PY
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

lib_report   | sort > "$work/lib"
cli_report   | sort > "$work/cli"
panel_report | sort > "$work/panel"

echo "1. the node container and the installer describe the same generations"
check "every line matches" "" "$(diff "$work/lib" "$work/cli" || true)"

echo "2. the panel agrees with the node container"
check "every line matches" "" "$(diff "$work/lib" "$work/panel" || true)"

echo "3. a generation is identified by the parameters it carries"
# If two generations listed the same parameters, nothing could tell them apart on the
# wire, and choosing between them would be a no-op.
check "each set is distinct" "3" "$(grep '^params\.' "$work/lib" | cut -f2 | sort -u | wc -l | tr -d ' ')"
# 3.0 exists upstream, but no router firmware speaks it, so a profile using it could
# never be loaded into a Keenetic. All three have to keep refusing it.
check "3.0 is refused by the node container" "refused" \
    "$(. "$ROOT/docker/awg/lib.sh"; awg_protocol 3.0 >/dev/null 2>&1 && echo accepted || echo refused)"
check "3.0 is refused by the panel" "refused" \
    "$(ROOT="$ROOT" python3 -c "
${load_panel_module}
try:
    p.normalize('3.0')
    print('accepted')
except p.UnknownProtocol:
    print('refused')")"

echo
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
