#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
COMPOSE_PROJECT_NAME="zero-downtime"
COMPOSE_FILE="compose/docker-compose.prod.yml"
DEPLOY_DIR=".deploy"
CURRENT_SHA_FILE="${DEPLOY_DIR}/current.sha"
PREVIOUS_SHA_FILE="${DEPLOY_DIR}/previous.sha"
ROLLED_BACK_FROM_FILE="${DEPLOY_DIR}/rolled-back-from.sha"
ROLLBACK_SHA=""
CURRENT_SHA=""
VERIFY_APP_URL=""

cd "$APP_DIR"

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//"/\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

send_alert() {
  local event="$1"
  local status="$2"
  local message="$3"
  local alert_app_url="${APP_URL:-${VERIFY_APP_URL:-}}"
  local payload

  payload=$(printf '{"project":"%s","environment":"%s","sha":"%s","appUrl":"%s","event":"%s","status":"%s","message":"%s"}' \
    "$(json_escape "Zero-Downtime Deployment Challenge")" \
    "$(json_escape "production")" \
    "$(json_escape "$ROLLBACK_SHA")" \
    "$(json_escape "$alert_app_url")" \
    "$(json_escape "$event")" \
    "$(json_escape "$status")" \
    "$(json_escape "$message")")

  if ! curl -fsS -X POST http://127.0.0.1:9001/notify \
    -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null; then
    echo "[warn] failed to send alert: ${event}" >&2
  fi

  return 0
}

fail_rollback() {
  local message="$1"

  echo "$message" >&2
  send_alert "rollback_failed" "error" "$message" || true
  exit 1
}

if [ ! -f "$PREVIOUS_SHA_FILE" ]; then
  fail_rollback "Rollback failed: target not found in ${PREVIOUS_SHA_FILE}."
fi

ROLLBACK_SHA="$(tr -d '[:space:]' < "$PREVIOUS_SHA_FILE")"

if [ -z "$ROLLBACK_SHA" ]; then
  fail_rollback "Rollback failed: target in ${PREVIOUS_SHA_FILE} is empty or invalid."
fi

if [ -f "$CURRENT_SHA_FILE" ]; then
  CURRENT_SHA="$(tr -d '[:space:]' < "$CURRENT_SHA_FILE")"
fi

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  fail_rollback "Rollback failed: cannot access Docker. Add the deploy user to the docker group or allow passwordless sudo for docker."
fi

COMPOSE=("${DOCKER[@]}" compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE")

if [ -n "${APP_URL:-}" ]; then
  VERIFY_APP_URL="$APP_URL"
elif [ -n "${EC2_HOST:-}" ]; then
  VERIFY_APP_URL="http://${EC2_HOST}"
else
  fail_rollback "Rollback failed: APP_URL or EC2_HOST is required for deployment verification."
fi

print_diagnostics() {
  echo "Rollback failed. Compose service status:"
  "${COMPOSE[@]}" ps || true
  echo "Recent backend logs:"
  "${COMPOSE[@]}" logs --tail=100 backend || true
  echo "Recent nginx logs:"
  "${COMPOSE[@]}" logs --tail=100 nginx || true
}

ROLLBACK_STAGE="preparing rollback"

handle_rollback_error() {
  local exit_code=$?
  local message="Rollback failed during ${ROLLBACK_STAGE} for target SHA ${ROLLBACK_SHA}."

  trap - ERR
  print_diagnostics
  send_alert "rollback_failed" "error" "$message" || true
  exit "$exit_code"
}

trap handle_rollback_error ERR

export IMAGE_TAG="$ROLLBACK_SHA"

echo "Starting rollback to ${ROLLBACK_SHA}."
if [ -n "$CURRENT_SHA" ]; then
  echo "Current deployment before rollback: ${CURRENT_SHA}"
  send_alert "rollback_started" "info" "Rollback started from SHA ${CURRENT_SHA} to SHA ${ROLLBACK_SHA}." || true
else
  send_alert "rollback_started" "info" "Rollback started to SHA ${ROLLBACK_SHA}; source SHA is unavailable." || true
fi

ROLLBACK_STAGE="pulling previous images"
"${COMPOSE[@]}" pull

ROLLBACK_STAGE="starting previous images"
"${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60

echo "Restarting nginx to refresh upstream resolution..."
ROLLBACK_STAGE="restarting nginx"
"${COMPOSE[@]}" restart nginx

"${COMPOSE[@]}" ps

ROLLBACK_STAGE="verifying the restored deployment"
./scripts/verify-deployment.sh "$VERIFY_APP_URL"

ROLLBACK_STAGE="updating rollback state files"
printf '%s\n' "$ROLLBACK_SHA" > "$CURRENT_SHA_FILE"

if [ -n "$CURRENT_SHA" ]; then
  printf '%s\n' "$CURRENT_SHA" > "$ROLLED_BACK_FROM_FILE"
fi

send_alert "rollback_success" "success" "Production recovered successfully at rollback target SHA ${ROLLBACK_SHA}." || true
echo "Rollback succeeded. Current deployment is now ${ROLLBACK_SHA}."
