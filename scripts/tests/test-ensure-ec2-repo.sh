#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
ENSURE_SCRIPT="${ROOT_DIR}/scripts/ensure-ec2-repo.sh"
TEST_ROOT="$(mktemp -d)"
MOCK_BIN="${TEST_ROOT}/bin"
MOCK_LOG="${TEST_ROOT}/git.log"
PASSED=0

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1" file="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain: ${pattern}"
}

assert_not_contains() {
  local pattern="$1" file="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "did not expect ${file} to contain: ${pattern}"
  fi
}

mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_GIT_LOG"

if [ "${1:-}" = --version ]; then
  echo 'git version 2.45.1'
  exit 0
fi

if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ]; then
  [ -f "$2/.mock-valid-git" ]
  exit $?
fi

if [ "${1:-}" = clone ]; then
  target="${@: -1}"
  mkdir -p "$target"
  if [ "${MOCK_GIT_MODE:-success}" = success ]; then
    mkdir -p "$target/.git"
    touch "$target/.mock-valid-git"
    echo "remote: clone progress"
    exit 0
  fi
  echo "fatal: unable to access '${MOCK_REPO_URL}': simulated clone failure" >&2
  touch "$target/incomplete-clone"
  exit 42
fi

echo "Unexpected mocked git arguments: $*" >&2
exit 99
MOCK_GIT
chmod +x "$MOCK_BIN/git"

run_ensure() {
  local mode="$1" app_dir="$2" output="$3"
  local repo_url="${4:-https://github.com/jackpac2/Zero-Downtime-Deployment-System.git}"
  MOCK_GIT_MODE="$mode" \
    MOCK_GIT_LOG="$MOCK_LOG" \
    MOCK_REPO_URL="$repo_url" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$ENSURE_SCRIPT" "$app_dir" "$repo_url" Main >"$output" 2>&1
}

success_dir="$TEST_ROOT/success/app"
success_output="$TEST_ROOT/success.out"
: > "$MOCK_LOG"
run_ensure success "$success_dir" "$success_output"
[ -d "$success_dir/.git" ] || fail "successful clone creates repository"
assert_contains 'git version 2.45.1' "$success_output"
assert_contains 'Repository host: github.com' "$success_output"
assert_contains 'Cloning branch Main' "$success_output"
assert_contains 'clone --progress --branch Main --' "$MOCK_LOG"
pass "successful clone reports version host and progress"

failure_dir="$TEST_ROOT/failure/app"
failure_output="$TEST_ROOT/failure.out"
credential_url='https://secret-user:secret-token@example.com/org/repository.git'
: > "$MOCK_LOG"
set +e
run_ensure failure "$failure_dir" "$failure_output" "$credential_url"
failure_status=$?
set -e
[ "$failure_status" -eq 42 ] || fail "failed clone preserves Git exit status"
[ ! -e "$failure_dir" ] || fail "failed clone removes newly created incomplete directory"
assert_contains 'Repository host: example.com' "$failure_output"
assert_contains '[credentials-redacted]@example.com' "$failure_output"
assert_not_contains 'secret-user' "$failure_output"
assert_not_contains 'secret-token' "$failure_output"
pass "failed clone is redacted and newly created partial directory is removed"

existing_repo="$TEST_ROOT/existing-repository"
existing_output="$TEST_ROOT/existing-repository.out"
mkdir -p "$existing_repo/.git"
touch "$existing_repo/.mock-valid-git" "$existing_repo/preserved"
: > "$MOCK_LOG"
run_ensure success "$existing_repo" "$existing_output"
[ -f "$existing_repo/preserved" ] || fail "existing repository content is preserved"
assert_not_contains 'clone --progress' "$MOCK_LOG"
pass "existing valid Git repository is left untouched"

non_git_dir="$TEST_ROOT/non-git"
non_git_output="$TEST_ROOT/non-git.out"
mkdir -p "$non_git_dir"
touch "$non_git_dir/preserved"
: > "$MOCK_LOG"
set +e
run_ensure success "$non_git_dir" "$non_git_output"
non_git_status=$?
set -e
[ "$non_git_status" -ne 0 ] || fail "existing non-empty non-Git directory is rejected"
[ -f "$non_git_dir/preserved" ] || fail "existing non-Git content is preserved"
assert_not_contains 'clone --progress' "$MOCK_LOG"
pass "existing non-empty non-Git directory is never deleted"

empty_dir="$TEST_ROOT/existing-empty"
empty_output="$TEST_ROOT/existing-empty.out"
mkdir -p "$empty_dir"
: > "$MOCK_LOG"
set +e
run_ensure failure "$empty_dir" "$empty_output"
empty_status=$?
set -e
[ "$empty_status" -eq 42 ] || fail "failed clone into existing empty directory preserves exit status"
[ -d "$empty_dir" ] || fail "existing empty target directory is preserved"
[ -f "$empty_dir/incomplete-clone" ] || fail "existing empty target is not cleaned as newly created"
pass "failed clone never removes a target directory that existed before the attempt"

printf '%s ensure EC2 repository tests passed.\n' "$PASSED"
