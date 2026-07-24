#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
HELPER="${ROOT_DIR}/scripts/lib/deployment-common.sh"
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

REPAIR_REPO="${TEST_ROOT}/router-repair-repo"
mkdir -p "$REPAIR_REPO/nginx" "$REPAIR_REPO/scripts" "$REPAIR_REPO/.deploy"
cp "$ROOT_DIR/nginx/router.conf.template" "$REPAIR_REPO/nginx/router.conf.template"
cp "$ROOT_DIR/scripts/render-router-config.sh" "$REPAIR_REPO/scripts/render-router-config.sh"
chmod +x "$REPAIR_REPO/scripts/render-router-config.sh"
"$REPAIR_REPO/scripts/render-router-config.sh" legacy > "$REPAIR_REPO/nginx/router.conf"
printf 'tracked\n' > "$REPAIR_REPO/README.md"
git -C "$REPAIR_REPO" init -q
git -C "$REPAIR_REPO" config user.name test
git -C "$REPAIR_REPO" config user.email test@example.invalid
git -C "$REPAIR_REPO" config core.autocrlf false
git -C "$REPAIR_REPO" add nginx scripts README.md
git -C "$REPAIR_REPO" commit -qm initial
printf 'stable-router\n' > "$REPAIR_REPO/.deploy/topology"
printf 'blue\n' > "$REPAIR_REPO/.deploy/active-color"
"$REPAIR_REPO/scripts/render-router-config.sh" blue > "$REPAIR_REPO/nginx/router.conf"
repair_dirty="$(git -C "$REPAIR_REPO" status --porcelain --untracked-files=no)"
reconcile_generated_router_checkout_change "$REPAIR_REPO" "$repair_dirty" >/dev/null || fail "known generated router reconciliation"
[ -z "$(git -C "$REPAIR_REPO" status --porcelain --untracked-files=no)" ] || fail "reconciliation leaves checkout dirty"
cmp -s <("$REPAIR_REPO/scripts/render-router-config.sh" blue) "$REPAIR_REPO/.deploy/router/router.conf" || fail "runtime router state preservation"
cmp -s <("$REPAIR_REPO/scripts/render-router-config.sh" legacy) "$REPAIR_REPO/nginx/router.conf" || fail "tracked router restoration"
pass "known generated router change moves to ignored runtime state and restores checkout"

printf 'unrelated change\n' >> "$REPAIR_REPO/README.md"
unrelated_dirty="$(git -C "$REPAIR_REPO" status --porcelain --untracked-files=no)"
if reconcile_generated_router_checkout_change "$REPAIR_REPO" "$unrelated_dirty" >/dev/null 2>&1; then
  fail "unrelated tracked change was reconciled"
fi
grep -Fq 'unrelated change' "$REPAIR_REPO/README.md" || fail "unrelated tracked change was altered"
pass "unrelated tracked changes still fail closed"
git -C "$REPAIR_REPO" restore --worktree -- README.md

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
