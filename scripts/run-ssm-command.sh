#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 --instance-id <id> --comment <text> (--user <name>|--root) --script <file> [-- <args...>]" >&2
}

INSTANCE_ID=""
COMMENT=""
EXECUTION_MODE=""
DEPLOY_USER=""
SCRIPT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance-id)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      INSTANCE_ID="$2"
      shift 2
      ;;
    --comment)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      COMMENT="$2"
      shift 2
      ;;
    --user)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      EXECUTION_MODE=user
      DEPLOY_USER="$2"
      shift 2
      ;;
    --root)
      EXECUTION_MODE=root
      shift
      ;;
    --script)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      SCRIPT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

SCRIPT_ARGS=("$@")

[[ "$INSTANCE_ID" =~ ^i-[0-9a-fA-F]{8}([0-9a-fA-F]{9})?$ ]] || {
  echo "Invalid EC2 instance ID: ${INSTANCE_ID:-missing}" >&2
  exit 1
}
[ -n "$COMMENT" ] && [ "${#COMMENT}" -le 100 ] || {
  echo "SSM command comment must contain between 1 and 100 characters." >&2
  exit 1
}
[ "$EXECUTION_MODE" = root ] || [ "$EXECUTION_MODE" = user ] || {
  echo "Choose exactly one execution mode: --root or --user." >&2
  exit 1
}
if [ "$EXECUTION_MODE" = user ]; then
  [[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
    echo "Invalid deployment user." >&2
    exit 1
  }
fi
[ -f "$SCRIPT_FILE" ] || {
  echo "SSM payload script not found: ${SCRIPT_FILE:-missing}" >&2
  exit 1
}
command -v aws >/dev/null 2>&1 || {
  echo "AWS CLI is required." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required." >&2
  exit 1
}
command -v base64 >/dev/null 2>&1 || {
  echo "base64 is required." >&2
  exit 1
}

payload="$(base64 -w 0 -- "$SCRIPT_FILE")"
printf -v quoted_user '%q' "$DEPLOY_USER"
quoted_args=""
for argument in "${SCRIPT_ARGS[@]}"; do
  printf -v quoted_argument '%q' "$argument"
  quoted_args+=" ${quoted_argument}"
done

if [ "$EXECUTION_MODE" = user ]; then
  execution_command=$(cat <<USER_COMMAND
target_group=\$(id -gn ${quoted_user})
chown ${quoted_user}:"\$target_group" "\$payload_file"
sudo -u ${quoted_user} -H -- bash "\$payload_file"${quoted_args}
USER_COMMAND
)
else
  execution_command="bash \"\$payload_file\"${quoted_args}"
fi

remote_command=$(cat <<REMOTE_COMMAND
set -euo pipefail
payload_file=\$(mktemp /var/tmp/zero-downtime-ssm.XXXXXX)
cleanup_payload() {
  rm -f -- "\$payload_file"
}
trap cleanup_payload EXIT
printf '%s' '${payload}' | base64 --decode > "\$payload_file"
chmod 0700 "\$payload_file"
${execution_command}
REMOTE_COMMAND
)

parameters_file="$(mktemp)"
invocation_file="$(mktemp)"
cleanup_local() {
  rm -f -- "$parameters_file" "$invocation_file"
}
trap cleanup_local EXIT
chmod 0600 "$parameters_file" "$invocation_file"

jq -n --arg command "$remote_command" '{commands: [$command]}' > "$parameters_file"

command_id="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "$COMMENT" \
  --parameters "file://${parameters_file}" \
  --query 'Command.CommandId' \
  --output text)"

if [ -z "$command_id" ] || [ "$command_id" = None ]; then
  echo "SSM SendCommand did not return a command ID." >&2
  exit 1
fi

echo "SSM command ID: ${command_id}" >&2

deadline=$((SECONDS + ${SSM_COMMAND_TIMEOUT_SECONDS:-1800}))
while true; do
  set +e
  aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --output json > "$invocation_file" 2>/dev/null
  get_status=$?
  set -e

  if [ "$get_status" -eq 0 ]; then
    status="$(jq -r '.Status // "Unknown"' "$invocation_file")"
    case "$status" in
      Pending|InProgress|Delayed|Cancelling)
        ;;
      *)
        break
        ;;
    esac
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting for SSM command ${command_id}." >&2
    exit 1
  fi
  sleep 5
done

response_code="$(jq -r '.ResponseCode // -1' "$invocation_file")"
standard_output="$(jq -r '.StandardOutputContent // ""' "$invocation_file")"
standard_error="$(jq -r '.StandardErrorContent // ""' "$invocation_file")"

if [ -n "$standard_output" ]; then
  printf '%s\n' "$standard_output"
fi
if [ -n "$standard_error" ]; then
  printf '%s\n' "$standard_error" >&2
fi
printf 'SSM command status: %s; response code: %s\n' "$status" "$response_code" >&2

if [ "$status" != Success ] || [ "$response_code" -ne 0 ]; then
  exit 1
fi
