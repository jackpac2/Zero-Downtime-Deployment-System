#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
R="${ROOT_DIR}/scripts/render-router-config.sh"; T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
fail(){ echo "not ok - $*" >&2; exit 1; }
for target in legacy blue green; do "$R" "$target" > "$T/$target.conf"; done
grep -Fq 'set $frontend_host app-frontend;' "$T/legacy.conf" && grep -Fq 'set $backend_host app-backend;' "$T/legacy.conf" || fail legacy
grep -Fq 'set $frontend_host blue-frontend;' "$T/blue.conf" && grep -Fq 'set $backend_host blue-backend;' "$T/blue.conf" || fail blue
grep -Fq 'set $frontend_host green-frontend;' "$T/green.conf" && grep -Fq 'set $backend_host green-backend;' "$T/green.conf" || fail green
for bad in '' purple '../blue' 'blue;id' $'blue\ngreen'; do "$R" "$bad" >/dev/null 2>&1 && fail "accepted unsafe target"; done
echo "ok - router allowlist and aliases"
diff -u <(tr -d '\r' < "$T/legacy.conf") <(tr -d '\r' < "${ROOT_DIR}/nginx/router.conf") >/dev/null || fail "legacy rendering differs from live router"
echo "ok - current production router remains legacy-compatible"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for target in legacy blue green; do docker run --rm --volume "$T/$target.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine nginx -t; done
  echo "ok - Nginx syntax validated for legacy Blue and Green"
else
  echo "not run - Nginx container validation: Docker daemon unavailable" >&2
fi
