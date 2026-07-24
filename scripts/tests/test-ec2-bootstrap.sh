#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/scripts/bootstrap-ec2-host.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/deploy.yml"
SSM_HELPER="${ROOT_DIR}/scripts/run-ssm-command.sh"
SSM_DEPLOYMENT_WRAPPER="${ROOT_DIR}/scripts/ssm-execute-deployment.sh"
COORDINATOR="${ROOT_DIR}/scripts/stable-router-deployment-coordinator.sh"
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

missing_aws_log=$(run_bootstrap_case "missing AWS CLI" "aws" true false success)
assert_file_contains "apt-get install -y --no-install-recommends awscli" "$missing_aws_log"
pass "missing AWS CLI is installed for secure SSM parameter retrieval"

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
assert_file_contains "Push-to-Main does not mutate EC2" "$WORKFLOW"
assert_file_contains "if: github.event_name == 'workflow_dispatch' && github.ref != 'refs/heads/Main'" "$WORKFLOW"
assert_file_not_contains "bootstrap_stable_router" "$WORKFLOW"
assert_file_not_contains "inputs.bootstrap_stable_router" "$WORKFLOW"
assert_file_not_contains "ssh " "$WORKFLOW"
assert_file_not_contains "scp " "$WORKFLOW"
assert_file_not_contains "EC2_SSH_KEY" "$WORKFLOW"
assert_file_not_contains "EC2_KNOWN_HOSTS" "$WORKFLOW"
assert_file_not_contains "~/.ssh" "$WORKFLOW"
assert_file_contains "id-token: write" "$WORKFLOW"
assert_file_contains "uses: aws-actions/configure-aws-credentials@v5" "$WORKFLOW"
assert_file_contains 'role-to-assume: ${{ vars.AWS_ROLE_ARN }}' "$WORKFLOW"
assert_file_contains 'aws-region: ${{ vars.AWS_REGION }}' "$WORKFLOW"
assert_file_contains 'EC2_INSTANCE_ID: ${{ vars.EC2_INSTANCE_ID }}' "$WORKFLOW"
assert_file_contains 'CONFIGURED_DEPLOY_USER: ${{ vars.EC2_DEPLOY_USER }}' "$WORKFLOW"
assert_file_not_contains 'secrets.EC2_HOST' "$WORKFLOW"
assert_file_contains 'aws ec2 describe-instances' "$WORKFLOW"
test "$(grep -Fc -- 'aws ec2 describe-instances' "$WORKFLOW")" -eq 1 || fail "expected exactly one EC2 DescribeInstances call"
assert_file_contains '--instance-ids "$EC2_INSTANCE_ID"' "$WORKFLOW"
assert_file_contains '--region "$AWS_REGION_VALUE"' "$WORKFLOW"
assert_file_contains '--query '\''Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress}'\''' "$WORKFLOW"
assert_file_contains 'if [ "$instance_state" != running ]; then' "$WORKFLOW"
assert_file_contains 'has no public IPv4 address' "$WORKFLOW"
assert_file_contains 'echo "::add-mask::$EC2_HOST"' "$WORKFLOW"
assert_file_contains 'echo "EC2_HOST=$EC2_HOST" >> "$GITHUB_ENV"' "$WORKFLOW"
assert_file_contains ': "${EC2_HOST:?Resolved EC2 public IPv4 address is unavailable}"' "$WORKFLOW"
assert_file_contains 'aws ssm put-parameter --cli-input-json' "$WORKFLOW"
assert_file_contains 'aws ssm delete-parameter --name' "$WORKFLOW"
assert_file_contains 'sudo -u ${quoted_user} -H -- bash' "$SSM_HELPER"
assert_file_contains 'aws ssm get-parameter' "$SSM_DEPLOYMENT_WRAPPER"
assert_file_contains '--with-decryption' "$SSM_DEPLOYMENT_WRAPPER"
assert_file_contains '--preserve-env=GHCR_USERNAME,GHCR_TOKEN,DISCORD_WEBHOOK_URL' "$SSM_DEPLOYMENT_WRAPPER"
assert_file_contains '-u "$DEPLOY_USER"' "$SSM_DEPLOYMENT_WRAPPER"
assert_file_not_contains 'echo "$GHCR_TOKEN"' "$SSM_DEPLOYMENT_WRAPPER"
pass "push guard OIDC SSM targeting deployment user and secret lifecycle are enforced"

line_prerequisites=$(grep -nF -- '- name: Install EC2 prerequisites' "$WORKFLOW" | cut -d: -f1)
line_aws_credentials=$(grep -nF -- '- name: Configure AWS credentials' "$WORKFLOW" | cut -d: -f1)
line_ec2_address=$(grep -nF -- '- name: Resolve EC2 public IPv4 address' "$WORKFLOW" | cut -d: -f1)
line_reconnect=$(grep -nF -- '- name: Verify Docker without sudo after reconnect' "$WORKFLOW" | cut -d: -f1)
line_repository=$(grep -nF -- '- name: Prepare exact EC2 repository commit' "$WORKFLOW" | cut -d: -f1)
line_topology=$(grep -nF -- '- name: Inspect topology marker' "$WORKFLOW" | cut -d: -f1)
line_migration=$(grep -nF -- '- name: Deploy through stable-router Blue/Green coordinator' "$WORKFLOW" | cut -d: -f1)
[ "$line_aws_credentials" -lt "$line_ec2_address" ] && \
  [ "$line_ec2_address" -lt "$line_prerequisites" ] && \
  [ "$line_prerequisites" -lt "$line_reconnect" ] && \
  [ "$line_reconnect" -lt "$line_repository" ] && \
  [ "$line_repository" -lt "$line_topology" ] && \
  [ "$line_topology" -lt "$line_migration" ] || fail "manual workflow ordering"
pass "bootstrap reconnect repository topology and migration ordering"

assert_file_contains 'case "$topology" in' "$COORDINATOR"
assert_file_contains 'absent)' "$COORDINATOR"
assert_file_contains 'stable-router)' "$COORDINATOR"
assert_file_contains 'Unknown topology marker value' "$COORDINATOR"
assert_file_contains './scripts/deploy.sh "$deploy_sha"' "$COORDINATOR"
assert_file_contains 'bash scripts/migrate-to-stable-router.sh "$deploy_sha"' "$COORDINATOR"
assert_file_contains 'Stable-router topology already active; migration is skipped.' "$COORDINATOR"
assert_file_contains './scripts/deploy-blue-green.sh "$deploy_sha"' "$COORDINATOR"
assert_file_contains 'verify_stable_router' "$COORDINATOR"
assert_file_contains 'test -x "$app_dir/scripts/deploy.sh"' "$WORKFLOW"
assert_file_contains 'test -f "$app_dir/scripts/migrate-to-stable-router.sh"' "$WORKFLOW"
assert_file_not_contains 'test -x "$app_dir/scripts/migrate-to-stable-router.sh"' "$WORKFLOW"
pass "topology branches mutate only an absent topology and always verify stable health"

assert_file_contains "'docker info >/dev/null'" "$WORKFLOW"
assert_file_contains "'docker compose version'" "$WORKFLOW"
assert_file_not_contains "continue-on-error" "$WORKFLOW"
pass "failed fresh-session Docker access blocks later mutation"

bash "$SCRIPT_DIR/test-ssm-run-command.sh"
pass "SSM command transport output and failure propagation"

bash "$SCRIPT_DIR/test-ensure-ec2-repo.sh"
pass "EC2 repository clone diagnostics and cleanup"

printf '%s EC2 bootstrap tests passed.\n' "$PASSED"
