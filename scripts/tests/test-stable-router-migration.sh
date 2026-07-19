#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
TRANSACTION_HELPER="${ROOT_DIR}/scripts/lib/stable-router-migration-transaction.sh"
COMMON_HELPER="${ROOT_DIR}/scripts/lib/deployment-common.sh"
MIGRATION_SCRIPT="${ROOT_DIR}/scripts/migrate-to-stable-router.sh"
TEST_ROOT="$(mktemp -d)"
LOG_FILE="${TEST_ROOT}/commands.log"
TOPOLOGY_FILE="${TEST_ROOT}/topology"
FAIL_AT=""
PASSED=0

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

# shellcheck source=scripts/lib/stable-router-migration-transaction.sh
source "$TRANSACTION_HELPER"

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  printf '%s\n' 'command log:' >&2
  cat "$LOG_FILE" >&2 2>/dev/null || true
  exit 1
}

record() {
  printf '%s\n' "$1" >> "$LOG_FILE"
  [ "$FAIL_AT" != "$1" ]
}

migration_preflight() { record preflight; }
migration_prepare_network() { record network; }
migration_pull_images() { record pull; }
migration_start_application() { record start-app; }
migration_verify_application() { record verify-app; }
migration_stop_legacy() { record stop-legacy; }
migration_verify_cutover_ports() { record verify-ports; }
migration_start_router() { record start-router; }
migration_verify_router() { record verify-router; }
migration_verify_public() { record verify-public; }
migration_capture_diagnostics() { record diagnostics || true; }
migration_cleanup_before_cutover() { record cleanup-pre-cutover || true; }
migration_stop_new_router() { record stop-new-router || true; }
migration_stop_new_application() { record stop-new-app || true; }
migration_restore_legacy() { record restore-legacy; }
migration_verify_restored_legacy() { record verify-restored-legacy; }
migration_print_manual_recovery() { record manual-recovery || true; }
migration_notify() { return 0; }
migration_report_success() { record success; }

migration_commit_state() {
  record commit-state || return 1
  printf '%s\n' stable-router > "${TOPOLOGY_FILE}.tmp"
  mv "${TOPOLOGY_FILE}.tmp" "$TOPOLOGY_FILE"
}

reset_case() {
  FAIL_AT="$1"
  : > "$LOG_FILE"
  rm -f "$TOPOLOGY_FILE" "${TOPOLOGY_FILE}.tmp"
  MIGRATION_PHASE="not-started"
  MIGRATION_LEGACY_STOPPED=false
  MIGRATION_PREPARATION_STARTED=false
}

assert_contains() {
  local value="$1"
  grep -qx "$value" "$LOG_FILE" || fail "expected '${value}'"
}

assert_not_contains() {
  local value="$1"
  if grep -qx "$value" "$LOG_FILE"; then
    fail "did not expect '${value}'"
  fi
}

run_expected_failure() {
  local name="$1"
  local failure_point="$2"
  local legacy_stopped="$3"

  reset_case "$failure_point"
  if run_stable_router_migration >/dev/null 2>&1; then
    fail "$name should fail"
  fi

  assert_contains diagnostics
  assert_not_contains success
  [ ! -f "$TOPOLOGY_FILE" ] || fail "$name wrote success topology state"

  if [ "$legacy_stopped" = true ]; then
    assert_contains stop-new-router
    assert_contains stop-new-app
    assert_contains restore-legacy
    assert_contains verify-restored-legacy
  else
    assert_not_contains stop-legacy
    assert_contains cleanup-pre-cutover
  fi
  pass "$name"
}

run_expected_preflight_failure() {
  local name="$1"

  reset_case preflight
  if run_stable_router_migration >/dev/null 2>&1; then
    fail "$name should fail"
  fi

  expected_order=$(cat <<'EOF'
preflight
diagnostics
EOF
)
  if [ "$(cat "$LOG_FILE")" != "$expected_order" ]; then
    fail "$name command ordering"
  fi

  for operation in \
    cleanup-pre-cutover \
    stop-legacy \
    start-router \
    commit-state \
    restore-legacy; do
    assert_not_contains "$operation"
  done
  assert_not_contains success
  [ ! -f "$TOPOLOGY_FILE" ] || fail "$name wrote success topology state"
  pass "$name"
}

# The real entry point must reject a short SHA before it can reach Docker or state.
if EC2_APP_DIR="$TEST_ROOT/does-not-exist" bash "$MIGRATION_SCRIPT" abcdef1 >/dev/null 2>&1; then
  fail "invalid SHA preflight"
else
  pass "invalid SHA preflight"
fi

for scenario in \
  "missing Docker access" \
  "invalid state SHA" \
  "Compose validation failure" \
  "Nginx validation failure" \
  "unexpected dirty checkout" \
  "lock or third-party port preflight"; do
  run_expected_preflight_failure "$scenario"
done

run_expected_failure "image pull failure" pull false
run_expected_failure "backend start failure" start-app false
run_expected_failure "candidate internal verification failure" verify-app false
run_expected_failure "candidate revision mismatch" verify-app false

# Failure after legacy shutdown must restore the full legacy stack.
run_expected_failure "port remains occupied after legacy shutdown" verify-ports true
run_expected_failure "router startup failure" start-router true
run_expected_failure "router health failure" verify-router true
run_expected_failure "public frontend or API failure" verify-public true
run_expected_failure "notifier health failure" verify-router true
run_expected_failure "state commit failure" commit-state true

reset_case ""
run_stable_router_migration >/dev/null
expected_order=$(cat <<'EOF'
preflight
network
pull
start-app
verify-app
stop-legacy
verify-ports
start-router
verify-router
verify-public
commit-state
success
EOF
)
if [ "$(cat "$LOG_FILE")" != "$expected_order" ]; then
  fail "successful migration command ordering"
fi
[ "$(<"$TOPOLOGY_FILE")" = stable-router ] || fail "successful atomic topology state"
pass "successful migration ordering and atomic state commit"

# Confirm a child restoration process can reuse the migration-owned lock.
if command -v flock >/dev/null 2>&1; then
  LOCK_DIR="${TEST_ROOT}/lock-state"
  # shellcheck source=scripts/lib/deployment-common.sh
  source "$COMMON_HELPER"
  ensure_deployment_state_dir "$LOCK_DIR"
  unset DEPLOY_LOCK_FD
  acquire_deployment_lock "$LOCK_DIR"
  bash -c '
    set -euo pipefail
    source "$1"
    acquire_deployment_lock "$2"
  ' _ "$COMMON_HELPER" "$LOCK_DIR"
  pass "restoration inherits the migration lock without deadlock"
else
  echo "not ok - lock inheritance not run: Linux flock is unavailable" >&2
  exit 2
fi

printf '%s migration tests passed.\n' "$PASSED"
