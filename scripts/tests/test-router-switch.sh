#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
source "${ROOT_DIR}/scripts/lib/router-switch.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT; mkdir -p "$T/.deploy" "$T/bin"
LOG="$T/docker.log"; RELOADS="$T/reloads"; : > "$LOG"; echo 0 > "$RELOADS"
cat > "$T/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_LOG"
if [[ " $* " == *" compose "*" ps -q nginx "* ]]; then echo router-id; exit 0; fi
if [ "${1:-}" = run ] && [ "${MOCK_VALIDATE_FAIL:-false}" = true ]; then exit 42; fi
if [[ "$*" == *'nginx -s reload'* ]]; then
  n=$(cat "$MOCK_RELOADS"); n=$((n+1)); echo "$n" > "$MOCK_RELOADS"
  [ "${MOCK_RELOAD_FAIL_ONCE:-false}" != true ] || [ "$n" -gt 1 ]
fi
exit 0
MOCK
chmod +x "$T/bin/docker"
export MOCK_LOG="$LOG" MOCK_RELOADS="$RELOADS"
APP_DIR="$T"; DOCKER=("$T/bin/docker"); ROUTER_COMPOSE=("$T/bin/docker" compose -p zero-downtime-router -f router.yml)
ROUTER_CONFIG="$T/router.conf"; ROUTER_RENDERER="${ROOT_DIR}/scripts/render-router-config.sh"
"$ROUTER_RENDERER" legacy > "$ROUTER_CONFIG"
MOCK_VALIDATE_FAIL=true; export MOCK_VALIDATE_FAIL
if render_and_validate_router_candidate blue >/dev/null 2>&1; then echo "not ok - failed Nginx validation accepted" >&2; exit 1; fi
unset MOCK_VALIDATE_FAIL
cmp -s "$ROUTER_CONFIG" <("$ROUTER_RENDERER" legacy) || { echo "not ok - validation failure changed traffic" >&2; exit 1; }
router_switch_cleanup; ROUTER_SWITCH_DIR=""; echo "ok - failed Nginx validation leaves traffic unchanged"
render_and_validate_router_candidate blue
MOCK_RELOAD_FAIL_ONCE=true; export MOCK_RELOAD_FAIL_ONCE
if apply_router_candidate; then echo "not ok - failed reload returned success" >&2; exit 1; fi
unset MOCK_RELOAD_FAIL_ONCE
cmp -s "$ROUTER_CONFIG" <("$ROUTER_RENDERER" legacy) || { echo "not ok - reload failure did not restore host config" >&2; exit 1; }
[ "$(cat "$RELOADS")" = 2 ] || { echo "not ok - restored config was not reloaded" >&2; exit 1; }
echo "ok - failed reload restores and reloads previous config"
line_validate=$(grep -n 'run --rm' "$LOG" | tail -1 | cut -d: -f1); line_reload=$(grep -n 'nginx -s reload' "$LOG" | head -1 | cut -d: -f1)
[ "$line_validate" -lt "$line_reload" ] || { echo "not ok - reload occurred before validation" >&2; exit 1; }
echo "ok - Nginx validation precedes active switch"
