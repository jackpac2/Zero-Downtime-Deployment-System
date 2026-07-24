#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
COMMON_HELPER="${ROOT_DIR}/scripts/lib/deployment-common.sh"
CANDIDATE_SCRIPT="${ROOT_DIR}/scripts/verify-color-candidate.sh"
COLOR_COMPOSE="${ROOT_DIR}/compose/docker-compose.app.yml"
LEGACY_APP_COMPOSE="${ROOT_DIR}/compose/docker-compose.app-legacy.yml"
ROUTER_CONFIG="${ROOT_DIR}/nginx/router.conf"
TEST_ROOT="$(mktemp -d)"
PASSED=0
DUMMY_SHA="0123456789abcdef0123456789abcdef01234567"

cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

# shellcheck source=scripts/lib/deployment-common.sh
source "$COMMON_HELPER"

pass() { PASSED=$((PASSED + 1)); printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

assert_equals() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "${label}: expected '${expected}', found '${actual}'"
}

assert_rejected() {
  local color="$1"
  if validate_deployment_color "$color" >/dev/null 2>&1; then
    fail "invalid color was accepted: ${color@Q}"
  fi
}

validate_deployment_color blue || fail "blue color validation"
assert_equals zero-downtime-blue "$(deployment_project_for_color blue)" "blue project"
assert_equals blue-frontend "$(frontend_alias_for_color blue)" "blue frontend alias"
assert_equals blue-backend "$(backend_alias_for_color blue)" "blue backend alias"
assert_equals green "$(opposite_deployment_color blue)" "blue opposite"
pass "valid Blue color resolution"

validate_deployment_color green || fail "green color validation"
assert_equals zero-downtime-green "$(deployment_project_for_color green)" "green project"
assert_equals green-frontend "$(frontend_alias_for_color green)" "green frontend alias"
assert_equals green-backend "$(backend_alias_for_color green)" "green backend alias"
assert_equals blue "$(opposite_deployment_color green)" "green opposite"
pass "valid Green color resolution"

for invalid_color in '' red BLUE ' blue' 'blue ' $'blue\ngreen' 'blue green' 'blue/green' '../blue' 'blue;id' 'blue --help'; do
  assert_rejected "$invalid_color"
done
pass "invalid empty whitespace path fragment and unknown colors are rejected"

[ "$(frontend_alias_for_color blue)" != "$(frontend_alias_for_color green)" ] || fail "frontend aliases overlap"
[ "$(backend_alias_for_color blue)" != "$(backend_alias_for_color green)" ] || fail "backend aliases overlap"
[ "$(deployment_project_for_color blue)" != "$(deployment_project_for_color green)" ] || fail "project names overlap"
pass "Blue and Green projects and aliases are unique"

STATE_DIR="${TEST_ROOT}/state"
write_active_deployment_color "$STATE_DIR" blue
assert_equals blue "$(read_active_deployment_color "$STATE_DIR")" "active color state"
write_candidate_deployment_color "$STATE_DIR" green
assert_equals green "$(read_candidate_deployment_color "$STATE_DIR")" "candidate color state"
write_color_deployment_sha "$STATE_DIR" blue "${DUMMY_SHA^^}"
assert_equals "$DUMMY_SHA" "$(read_color_deployment_sha "$STATE_DIR" blue)" "blue SHA state"
write_color_deployment_sha "$STATE_DIR" green "$DUMMY_SHA"
assert_equals "$DUMMY_SHA" "$(read_color_deployment_sha "$STATE_DIR" green)" "green SHA state"
if find "$STATE_DIR" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .; then
  fail "atomic state write left a temporary file"
fi
pass "color and SHA state writes are atomic and normalized"

if write_active_deployment_color "$STATE_DIR" red >/dev/null 2>&1; then fail "invalid active color write succeeded"; fi
assert_equals blue "$(read_active_deployment_color "$STATE_DIR")" "active color after rejected write"
if write_color_deployment_sha "$STATE_DIR" blue deadbeef >/dev/null 2>&1; then fail "invalid color SHA write succeeded"; fi
assert_equals "$DUMMY_SHA" "$(read_color_deployment_sha "$STATE_DIR" blue)" "blue SHA after rejected write"
pass "invalid state writes fail closed without replacing valid state"

printf 'invalid\n' > "$STATE_DIR/active-color"
if read_active_deployment_color "$STATE_DIR" >/dev/null 2>&1; then fail "invalid active-color state was accepted"; fi
printf 'blue green\n' > "$STATE_DIR/candidate-color"
if read_candidate_deployment_color "$STATE_DIR" >/dev/null 2>&1; then fail "invalid candidate-color state was accepted"; fi
printf 'short-sha\n' > "$STATE_DIR/green.sha"
if read_color_deployment_sha "$STATE_DIR" green >/dev/null 2>&1; then fail "invalid green SHA state was accepted"; fi
pass "invalid active candidate and color SHA state fails closed"

if bash "$CANDIDATE_SCRIPT" purple "$DUMMY_SHA" >/dev/null 2>&1; then fail "candidate verifier accepted invalid color"; fi
if bash "$CANDIDATE_SCRIPT" blue deadbeef >/dev/null 2>&1; then fail "candidate verifier accepted invalid SHA"; fi
pass "candidate verification rejects invalid inputs before Docker access"

MOCK_BIN="${TEST_ROOT}/bin"
MOCK_LOG="${TEST_ROOT}/docker.log"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
case "${1:-}" in
  info|compose|run) exit 0 ;;
  ps)
    if [[ " $* " == *' -aq '* ]]; then
      echo candidate-container
    elif [[ " $* " == *' --format '* ]]; then
      printf 'frontend\nbackend\n'
    elif [[ " $* " == *' -q '* ]]; then
      color=blue; [[ " $* " == *'zero-downtime-green'* ]] && color=green
      service=frontend; [[ " $* " == *'service=backend'* ]] && service=backend
      printf '%s-%s-id\n' "$color" "$service"
    fi
    ;;
  inspect)
    format="${3:-}"; container_id="${4:-}"
    if [[ "$format" == *'.Image'* ]]; then
      printf '%s-image\n' "$container_id"
    elif [[ "$format" == *'Aliases'* ]]; then
      color="${container_id%%-*}"; service=frontend
      [[ "$container_id" == *'-backend-'* ]] && service=backend
      printf '%s-%s\n' "$color" "$service"
    else
      echo zero-downtime-router
    fi
    ;;
  image) printf '%s\n' "$EXPECTED_SHA" ;;
  *) echo "unexpected docker command: $*" >&2; exit 99 ;;
esac
MOCK_DOCKER
chmod +x "$MOCK_BIN/docker"

for color in blue green; do
  : > "$MOCK_LOG"
  MOCK_DOCKER_LOG="$MOCK_LOG" PATH="$MOCK_BIN:$PATH" \
    bash "$CANDIDATE_SCRIPT" "$color" "$DUMMY_SHA" > "${TEST_ROOT}/${color}.out"
  grep -Fq "Candidate verification passed for zero-downtime-${color}" "${TEST_ROOT}/${color}.out" || fail "${color} candidate success output"
  grep -Fq "compose -p zero-downtime-${color} -f compose/docker-compose.app.yml config --quiet" "$MOCK_LOG" || fail "${color} candidate Compose project"
  grep -Fq 'run --rm --network zero-downtime-router' "$MOCK_LOG" || fail "${color} candidate internal verification"
  if grep -Eq -- '--publish|-p [0-9]|restart|reload' "$MOCK_LOG"; then fail "${color} candidate attempted traffic mutation"; fi
done
pass "mocked Blue and Green candidate verification is internal and non-mutating"

grep -Fq '${DEPLOY_COLOR:?DEPLOY_COLOR must be blue or green}-frontend' "$COLOR_COMPOSE" || fail "color frontend interpolation"
grep -Fq '${DEPLOY_COLOR:?DEPLOY_COLOR must be blue or green}-backend' "$COLOR_COMPOSE" || fail "color backend interpolation"
if grep -Eq 'app-frontend|app-backend' "$COLOR_COMPOSE"; then fail "color Compose claims live aliases"; fi
grep -Fq 'app-frontend' "$LEGACY_APP_COMPOSE" || fail "legacy frontend alias compatibility"
grep -Fq 'app-backend' "$LEGACY_APP_COMPOSE" || fail "legacy backend alias compatibility"
grep -Fq 'app-frontend' "$ROUTER_CONFIG" || fail "live router frontend target changed"
grep -Fq 'app-backend' "$ROUTER_CONFIG" || fail "live router backend target changed"
grep -Fq '../.deploy/router/router.conf:/etc/nginx/conf.d/default.conf:ro' "${ROOT_DIR}/compose/docker-compose.router.yml" || fail "router does not mount ignored runtime config"
if grep -Eiq 'nginx[[:space:]].*(-s[[:space:]]+reload|restart)|docker[[:space:]]+compose.*(restart|down)' "$CANDIDATE_SCRIPT"; then
  fail "candidate verifier contains a traffic-switch command"
fi
pass "color Compose avoids live aliases and production router targets remain unchanged"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  DEPLOY_COLOR=blue IMAGE_TAG="$DUMMY_SHA" docker compose -p zero-downtime-blue -f "$COLOR_COMPOSE" config > "${TEST_ROOT}/blue.yml"
  DEPLOY_COLOR=green IMAGE_TAG="$DUMMY_SHA" docker compose -p zero-downtime-green -f "$COLOR_COMPOSE" config > "${TEST_ROOT}/green.yml"
  grep -Fq blue-frontend "${TEST_ROOT}/blue.yml" || fail "rendered Blue frontend alias"
  grep -Fq blue-backend "${TEST_ROOT}/blue.yml" || fail "rendered Blue backend alias"
  grep -Fq green-frontend "${TEST_ROOT}/green.yml" || fail "rendered Green frontend alias"
  grep -Fq green-backend "${TEST_ROOT}/green.yml" || fail "rendered Green backend alias"
  if grep -Eq 'app-frontend|app-backend|green-(frontend|backend)' "${TEST_ROOT}/blue.yml"; then fail "rendered Blue contains conflicting aliases"; fi
  if grep -Eq 'app-frontend|app-backend|blue-(frontend|backend)' "${TEST_ROOT}/green.yml"; then fail "rendered Green contains conflicting aliases"; fi
  pass "Blue and Green Compose configurations render independently"
else
  echo "not run - Blue/Green Compose rendering: Docker Compose is unavailable" >&2
fi

printf '%s Blue/Green preparation tests passed.\n' "$PASSED"
