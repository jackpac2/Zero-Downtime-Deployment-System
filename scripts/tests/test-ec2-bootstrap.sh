#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/scripts/bootstrap-ec2-host.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/deploy.yml"
TEST_ROOT="$(mktemp -d)"
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

assert_file_contains() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected ${file} to contain: ${pattern}"
}

assert_file_not_contains() {
  local pattern="$1"
  local file="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "did not expect ${file} to contain: ${pattern}"
  fi
}

run_bootstrap_case() {
  local name="$1"
  local missing="$2"
  local in_group="$3"
  local install_failure="$4"
  local expected_status="$5"
  local docker_info_works="${6:-true}"
  local log_file="${TEST_ROOT}/${name// /-}.log"
  local output_file="${TEST_ROOT}/${name// /-}.out"
  local actual_status=0

  set +e
  BOOTSTRAP_TEST_MODE=true \
    BOOTSTRAP_ACTION_LOG="$log_file" \
    BOOTSTRAP_MISSING_ITEMS="$missing" \
    BOOTSTRAP_USER_IN_DOCKER_GROUP="$in_group" \
    BOOTSTRAP_DOCKER_INFO_WORKS="$docker_info_works" \
    BOOTSTRAP_PACKAGE_INSTALL_FAIL="$install_failure" \
    bash "$BOOTSTRAP_SCRIPT" >"$output_file" 2>&1
  actual_status=$?
  set -e

  if [ "$expected_status" = success ] && [ "$actual_status" -ne 0 ]; then
    cat "$output_file" >&2
    fail "$name"
  fi
  if [ "$expected_status" = failure ] && [ "$actual_status" -eq 0 ]; then
    cat "$output_file" >&2
    fail "$name"
  fi
  printf '%s\n' "$log_file"
}

all_present_log=$(run_bootstrap_case "all tools present" "" true false success)
assert_file_not_contains "apt-get update" "$all_present_log"
assert_file_not_contains "apt-get install" "$all_present_log"
assert_file_contains "systemctl enable --now docker" "$all_present_log"
pass "all installed prerequisites avoid apt"

missing_flock_log=$(run_bootstrap_case "missing flock" "flock util-linux" true false success)
assert_file_contains "apt-get install -y --no-install-recommends util-linux" "$missing_flock_log"
pass "missing flock installs util-linux"

missing_git_log=$(run_bootstrap_case "missing git" "git" true false success)
assert_file_contains "apt-get install -y --no-install-recommends git" "$missing_git_log"
pass "missing Git is installed"

missing_docker_log=$(run_bootstrap_case "missing Docker" "docker docker-compose" true false success)
assert_file_contains "configure official Docker apt repository" "$missing_docker_log"
assert_file_contains "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" "$missing_docker_log"
pass "missing Docker uses official packages"

missing_compose_log=$(run_bootstrap_case "missing Compose" "docker-compose" true false success)
assert_file_contains "configure official Docker apt repository" "$missing_compose_log"
assert_file_contains "apt-get install -y --no-install-recommends docker-compose-plugin" "$missing_compose_log"
pass "missing Compose installs the plugin"

run_bootstrap_case "package failure" "git" true true failure >/dev/null
pass "package installation failure blocks bootstrap"

already_permitted_log=$(run_bootstrap_case "Docker already permitted" "" false false success true)
assert_file_not_contains "usermod -aG docker" "$already_permitted_log"
pass "Docker already working without sudo avoids group mutation"

group_change_log=$(run_bootstrap_case "Docker group change" "" false false success false)
assert_file_contains "usermod -aG docker ubuntu" "$group_change_log"
pass "deployment user is added to Docker group when required"

resolution_statement=$(grep -F 'app_dir="${CONFIGURED_EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"' "$WORKFLOW" | sed 's/^[[:space:]]*//')
[ -n "$resolution_statement" ] || fail "EC2_APP_DIR resolution statement"
CONFIGURED_EC2_APP_DIR=/srv/zero-downtime
eval "$resolution_statement"
[ "$app_dir" = /srv/zero-downtime ] || fail "supplied EC2_APP_DIR"
pass "supplied EC2_APP_DIR is preserved"
CONFIGURED_EC2_APP_DIR=
eval "$resolution_statement"
[ "$app_dir" = /home/ubuntu/Zero-Downtime-Deployment-System ] || fail "empty EC2_APP_DIR fallback"
pass "empty EC2_APP_DIR uses the exact fallback"
assert_file_contains "EC2_APP_DIR must be a non-root absolute path on one line." "$WORKFLOW"
assert_file_not_contains 'sudo install -d -o "$(id -un)" -g "$(id -gn)" "$parent"' "$WORKFLOW"
pass "unsafe app paths and parent ownership changes are rejected"

manual_condition="github.event_name == 'workflow_dispatch'"
manual_step_count=$(grep -Fc "if: ${manual_condition}" "$WORKFLOW")
[ "$manual_step_count" -ge 5 ] || fail "manual EC2 steps are not consistently dispatch-gated"
assert_file_contains "if: github.event_name == 'push'" "$WORKFLOW"
assert_file_contains "EC2 deployment is temporarily manual" "$WORKFLOW"
assert_file_contains "if: github.event_name == 'workflow_dispatch' && github.ref != 'refs/heads/Main'" "$WORKFLOW"
assert_file_not_contains "bootstrap_stable_router" "$WORKFLOW"
assert_file_not_contains "inputs.bootstrap_stable_router" "$WORKFLOW"
assert_file_not_contains "ssh-keyscan" "$WORKFLOW"
assert_file_not_contains "EC2_KNOWN_HOSTS" "$WORKFLOW"
assert_file_contains "StrictHostKeyChecking accept-new" "$WORKFLOW"
pass "push guard direct manual dispatch Main restriction and SSH trust-on-first-use are enforced"

line_prerequisites=$(grep -nF -- '- name: Install EC2 prerequisites' "$WORKFLOW" | cut -d: -f1)
line_reconnect=$(grep -nF -- '- name: Verify Docker without sudo after reconnect' "$WORKFLOW" | cut -d: -f1)
line_repository=$(grep -nF -- '- name: Prepare exact EC2 repository commit' "$WORKFLOW" | cut -d: -f1)
line_topology=$(grep -nF -- '- name: Inspect topology marker' "$WORKFLOW" | cut -d: -f1)
line_migration=$(grep -nF -- '- name: Deploy legacy stack and run one-time migration' "$WORKFLOW" | cut -d: -f1)
[ "$line_prerequisites" -lt "$line_reconnect" ] && \
  [ "$line_reconnect" -lt "$line_repository" ] && \
  [ "$line_repository" -lt "$line_topology" ] && \
  [ "$line_topology" -lt "$line_migration" ] || fail "manual workflow ordering"
pass "bootstrap reconnect repository topology and migration ordering"

assert_file_contains 'case "$topology" in' "$WORKFLOW"
assert_file_contains 'absent)' "$WORKFLOW"
assert_file_contains 'stable-router)' "$WORKFLOW"
assert_file_contains 'Unknown topology marker value' "$WORKFLOW"
assert_file_contains './scripts/deploy.sh "$deploy_sha"' "$WORKFLOW"
assert_file_contains 'bash scripts/migrate-to-stable-router.sh "$deploy_sha"' "$WORKFLOW"
assert_file_contains 'The one-time stable-router migration has already completed; verifying without mutation.' "$WORKFLOW"
assert_file_contains 'verify_stable_router' "$WORKFLOW"
assert_file_contains 'test -x "$app_dir/scripts/deploy.sh"' "$WORKFLOW"
assert_file_contains 'test -f "$app_dir/scripts/migrate-to-stable-router.sh"' "$WORKFLOW"
assert_file_not_contains 'test -x "$app_dir/scripts/migrate-to-stable-router.sh"' "$WORKFLOW"
pass "topology branches mutate only an absent topology and always verify stable health"

assert_file_contains "'set -euo pipefail; docker info >/dev/null; docker compose version'" "$WORKFLOW"
assert_file_not_contains "continue-on-error" "$WORKFLOW"
pass "failed fresh-session Docker access blocks later mutation"

bash "$SCRIPT_DIR/test-ensure-ec2-repo.sh"
pass "EC2 repository clone diagnostics and cleanup"

printf '%s EC2 bootstrap tests passed.\n' "$PASSED"
