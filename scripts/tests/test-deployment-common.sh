#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER="$(cd "${SCRIPT_DIR}/../lib" && pwd -P)/deployment-common.sh"
TEST_ROOT="$(mktemp -d)"
PASSED=0

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

# shellcheck source=scripts/lib/deployment-common.sh
source "$HELPER"

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

expect_valid_sha() {
  local name="$1"
  local sha="$2"

  if validate_deployment_sha "$sha" "$name" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_invalid_sha() {
  local name="$1"
  local sha="${2-}"

  if validate_deployment_sha "$sha" "$name" >/dev/null 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

LOWER_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
UPPER_SHA="ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD"

expect_valid_sha "valid lowercase SHA" "$LOWER_SHA"
expect_valid_sha "valid uppercase SHA" "$UPPER_SHA"
expect_invalid_sha "empty SHA" ""
expect_invalid_sha "seven-character SHA" "abcdef1"
expect_invalid_sha "thirty-nine-character SHA" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_invalid_sha "forty-one-character SHA" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_invalid_sha "non-hexadecimal SHA" "gaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_invalid_sha "SHA containing a space" "aaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa"
expect_invalid_sha "SHA containing a newline" $'aaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaa'

LOCK_STATE_DIR="${TEST_ROOT}/state"
READY_FILE="${TEST_ROOT}/holder-ready"
ensure_deployment_state_dir "$LOCK_STATE_DIR"

(
  unset DEPLOY_LOCK_FD
  acquire_deployment_lock "$LOCK_STATE_DIR"
  : > "$READY_FILE"
  sleep 1
) &
holder_pid=$!

for _attempt in $(seq 1 50); do
  [ -f "$READY_FILE" ] && break
  sleep 0.05
done

[ -f "$READY_FILE" ] || fail "first process acquires the lock"
pass "first process acquires the lock"

if (
  unset DEPLOY_LOCK_FD
  acquire_deployment_lock "$LOCK_STATE_DIR"
) >/dev/null 2>&1; then
  fail "second process is rejected while lock is held"
else
  pass "second process is rejected while lock is held"
fi

wait "$holder_pid"

if (
  unset DEPLOY_LOCK_FD
  acquire_deployment_lock "$LOCK_STATE_DIR"
); then
  pass "lock is available after holder exits"
else
  fail "lock is available after holder exits"
fi

if (
  unset DEPLOY_LOCK_FD
  acquire_deployment_lock "$LOCK_STATE_DIR"
  bash -c '
    set -euo pipefail
    source "$1"
    acquire_deployment_lock "$2"
  ' _ "$HELPER" "$LOCK_STATE_DIR"
); then
  pass "internal rollback process inherits the deployment lock"
else
  fail "internal rollback process inherits the deployment lock"
fi

printf '%s tests passed.\n' "$PASSED"
