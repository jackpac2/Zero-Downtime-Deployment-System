#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
SSM_HELPER="${ROOT_DIR}/scripts/run-ssm-command.sh"
SSM_DEPLOYMENT_WRAPPER="${ROOT_DIR}/scripts/ssm-execute-deployment.sh"
TEST_ROOT="$(mktemp -d)"
MOCK_BIN="${TEST_ROOT}/bin"
AWS_LOG="${TEST_ROOT}/aws.log"
PARAMETERS_CAPTURE="${TEST_ROOT}/parameters.json"
PAYLOAD_SCRIPT="${TEST_ROOT}/payload.sh"
APP_DIR="${TEST_ROOT}/app"
COORDINATOR="${APP_DIR}/scripts/stable-router-deployment-coordinator.sh"
SUDO_LOG="${TEST_ROOT}/sudo.log"

cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected $2 to contain: $1"; }

mkdir -p "$MOCK_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo payload-ran' > "$PAYLOAD_SCRIPT"

cat > "$MOCK_BIN/jq" <<'MOCK_JQ'
#!/usr/bin/env node
const fs = require('fs')
const args = process.argv.slice(2)
if (args[0] === '-n') {
  const commandIndex = args.indexOf('--arg')
  const command = args[commandIndex + 2]
  process.stdout.write(JSON.stringify({commands: [command]}))
  process.exit(0)
}
const expression = args[1]
const input = JSON.parse(fs.readFileSync(args[2], 'utf8'))
const fields = {
  '.Status // "Unknown"': input.Status ?? 'Unknown',
  '.ResponseCode // -1': input.ResponseCode ?? -1,
  '.StandardOutputContent // ""': input.StandardOutputContent ?? '',
  '.StandardErrorContent // ""': input.StandardErrorContent ?? ''
}
process.stdout.write(String(fields[expression] ?? ''))
MOCK_JQ

cat > "$MOCK_BIN/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_AWS_LOG"
case "$*" in
  'ssm send-command'*)
    for argument in "$@"; do
      case "$argument" in
        file://*) cp "${argument#file://}" "$MOCK_PARAMETERS_CAPTURE" ;;
      esac
    done
    [ "${MOCK_EMPTY_COMMAND_ID:-false}" = true ] || echo 11111111-2222-3333-4444-555555555555
    ;;
  'ssm get-command-invocation'*)
    if [ "${MOCK_REMOTE_FAILURE:-false}" = true ]; then
      printf '%s\n' '{"Status":"Failed","ResponseCode":42,"StandardOutputContent":"partial output","StandardErrorContent":"remote failure details"}'
    else
      printf '%s\n' '{"Status":"Success","ResponseCode":0,"StandardOutputContent":"remote output","StandardErrorContent":""}'
    fi
    ;;
  'ssm get-parameter'*)
    echo mock-secret
    ;;
  *) exit 99 ;;
esac
MOCK_AWS
chmod +x "$MOCK_BIN/jq" "$MOCK_BIN/aws"

MOCK_AWS_LOG="$AWS_LOG" MOCK_PARAMETERS_CAPTURE="$PARAMETERS_CAPTURE" PATH="$MOCK_BIN:$PATH" \
  bash "$SSM_HELPER" \
    --instance-id i-0123456789abcdef0 \
    --comment "mock success" \
    --user ubuntu \
    --script "$PAYLOAD_SCRIPT" \
    -- '/srv/zero downtime' > "$TEST_ROOT/success.out" 2> "$TEST_ROOT/success.err"

assert_contains 'remote output' "$TEST_ROOT/success.out"
assert_contains 'SSM command ID: 11111111-2222-3333-4444-555555555555' "$TEST_ROOT/success.err"
assert_contains 'SSM command status: Success; response code: 0' "$TEST_ROOT/success.err"
assert_contains 'ssm send-command --instance-ids i-0123456789abcdef0 --document-name AWS-RunShellScript' "$AWS_LOG"
assert_contains 'ssm get-command-invocation --command-id 11111111-2222-3333-4444-555555555555' "$AWS_LOG"
assert_contains 'sudo -u ubuntu -H -- bash' "$PARAMETERS_CAPTURE"
assert_contains 'chown ubuntu:' "$PARAMETERS_CAPTURE"
pass "successful SSM command prints output status and response code"

set +e
MOCK_REMOTE_FAILURE=true MOCK_AWS_LOG="$AWS_LOG" MOCK_PARAMETERS_CAPTURE="$PARAMETERS_CAPTURE" PATH="$MOCK_BIN:$PATH" \
  bash "$SSM_HELPER" \
    --instance-id i-0123456789abcdef0 \
    --comment "mock failure" \
    --root \
    --script "$PAYLOAD_SCRIPT" > "$TEST_ROOT/failure.out" 2> "$TEST_ROOT/failure.err"
failure_status=$?
set -e
[ "$failure_status" -ne 0 ] || fail "remote failure returned success"
assert_contains 'partial output' "$TEST_ROOT/failure.out"
assert_contains 'remote failure details' "$TEST_ROOT/failure.err"
assert_contains 'SSM command status: Failed; response code: 42' "$TEST_ROOT/failure.err"
pass "failed SSM response prints diagnostics and fails locally"

set +e
MOCK_EMPTY_COMMAND_ID=true MOCK_AWS_LOG="$AWS_LOG" MOCK_PARAMETERS_CAPTURE="$PARAMETERS_CAPTURE" PATH="$MOCK_BIN:$PATH" \
  bash "$SSM_HELPER" \
    --instance-id i-0123456789abcdef0 \
    --comment "missing command id" \
    --root \
    --script "$PAYLOAD_SCRIPT" > /dev/null 2> "$TEST_ROOT/empty.err"
empty_status=$?
set -e
[ "$empty_status" -ne 0 ] || fail "missing command ID returned success"
assert_contains 'did not return a command ID' "$TEST_ROOT/empty.err"
pass "missing SSM command ID fails closed"

mkdir -p "$APP_DIR/.git" "$(dirname "$COORDINATOR")"
: > "$COORDINATOR"

cat > "$MOCK_BIN/id" <<'MOCK_ID'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then
  echo 0
  exit 0
fi
[ "$#" -eq 1 ] && exit 0
exit 1
MOCK_ID

cat > "$MOCK_BIN/sudo" <<'MOCK_SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_SUDO_LOG"
MOCK_SUDO
chmod +x "$MOCK_BIN/id" "$MOCK_BIN/sudo"

parameter_prefix=/zero-downtime-deployment/github-actions/123456789-1
MOCK_AWS_LOG="$AWS_LOG" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" \
  bash "$SSM_DEPLOYMENT_WRAPPER" \
    ubuntu "$APP_DIR" 0000000000000000000000000000000000000000 203.0.113.10 us-east-1 \
    "$parameter_prefix/ghcr-username" \
    "$parameter_prefix/ghcr-token" \
    "$parameter_prefix/discord-webhook" \
    "$COORDINATOR"
assert_contains "ssm get-parameter --region us-east-1 --name $parameter_prefix/ghcr-username" "$AWS_LOG"
assert_contains '-u ubuntu -H -- bash' "$SUDO_LOG"
pass "generated secure parameter paths are accepted"
set +e
MOCK_AWS_LOG="$AWS_LOG" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" \
  bash "$SSM_DEPLOYMENT_WRAPPER" \
    ubuntu "$APP_DIR" 0000000000000000000000000000000000000000 not-an-ip us-east-1 \
    "" "" "" "$COORDINATOR" \
    > /dev/null 2> "$TEST_ROOT/invalid-public-ip.err"
invalid_ip_status=$?
set -e
[ "$invalid_ip_status" -ne 0 ] || fail "invalid inferred public IP returned success"
assert_contains 'Invalid inferred EC2 public IPv4 address.' "$TEST_ROOT/invalid-public-ip.err"
pass "invalid inferred public IP fails closed"

for invalid_parameter in \
  "$parameter_prefix/bad name" \
  "$parameter_prefix/\$(id)" \
  ../outside; do
  set +e
  MOCK_AWS_LOG="$AWS_LOG" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" \
    bash "$SSM_DEPLOYMENT_WRAPPER" \
      ubuntu "$APP_DIR" 0000000000000000000000000000000000000000 203.0.113.10 us-east-1 \
      "$invalid_parameter" "" "" "$COORDINATOR" \
      > /dev/null 2> "$TEST_ROOT/invalid-parameter.err"
  invalid_status=$?
  set -e
  [ "$invalid_status" -ne 0 ] || fail "unsafe parameter name returned success: $invalid_parameter"
  assert_contains 'Invalid secure parameter name.' "$TEST_ROOT/invalid-parameter.err"
done
pass "unsafe secure parameter paths fail closed"

printf '6 SSM deployment transport tests passed.\n'
