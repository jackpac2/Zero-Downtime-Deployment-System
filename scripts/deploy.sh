#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "Usage: $0 <git-sha>" >&2
  exit 1
fi

GIT_SHA="$1"
APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
BRANCH="Main"
COMPOSE_PROJECT_NAME="zero-downtime"
COMPOSE_FILE="compose/docker-compose.prod.yml"
DEPLOY_DIR=".deploy"
CURRENT_SHA_FILE="${DEPLOY_DIR}/current.sha"
PREVIOUS_SHA_FILE="${DEPLOY_DIR}/previous.sha"
FAILED_SHA_FILE="${DEPLOY_DIR}/failed.sha"
ROLLBACK_TARGET_READY=false
DEPLOYMENT_ATTEMPT_ACTIVE=false
ROLLBACK_IN_PROGRESS=false
ROLLBACK_ATTEMPTED=false
DEPLOYMENT_COMPLETED=false
DEPLOYMENT_FAILED_ALERT_SENT=false
DEPLOYMENT_STAGE="setup"

cd "$APP_DIR"

git config core.fileMode false
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

mkdir -p "$DEPLOY_DIR"

OLD_CURRENT_SHA=""
if [ -f "$CURRENT_SHA_FILE" ]; then
  OLD_CURRENT_SHA="$(tr -d '[:space:]' < "$CURRENT_SHA_FILE")"
fi

if [ -n "$OLD_CURRENT_SHA" ]; then
  printf '%s\n' "$OLD_CURRENT_SHA" > "$PREVIOUS_SHA_FILE"
  ROLLBACK_TARGET_READY=true
fi

export IMAGE_TAG="$GIT_SHA"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "Cannot access Docker. Add the deploy user to the docker group or allow passwordless sudo for docker." >&2
  exit 1
fi

COMPOSE=("${DOCKER[@]}" compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE")

if [ -n "${APP_URL:-}" ]; then
  VERIFY_APP_URL="$APP_URL"
elif [ -n "${EC2_HOST:-}" ]; then
  VERIFY_APP_URL="http://${EC2_HOST}"
else
  echo "APP_URL or EC2_HOST is required for Phase 7 deployment verification." >&2
  echo "Set APP_URL to the public app URL or EC2_HOST to the public EC2 hostname/IP." >&2
  exit 1
fi

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
    "$(json_escape "$GIT_SHA")" \
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

dump_compose_diagnostics() {
  echo "Deployment failed. Compose service status:"
  "${COMPOSE[@]}" ps || true
  echo "Recent backend logs:"
  "${COMPOSE[@]}" logs --tail=100 backend || true
  echo "Recent nginx logs:"
  "${COMPOSE[@]}" logs --tail=100 nginx || true
}

handle_deployment_failure() {
  local original_exit_code=$?
  local rollback_exit_code
  local failure_message

  # Disable the trap immediately so failures during diagnostics or rollback cannot recurse.
  trap - ERR

  if [ "$original_exit_code" -eq 0 ]; then
    original_exit_code=1
  fi

  if [ "$DEPLOYMENT_ATTEMPT_ACTIVE" != true ] || [ "$DEPLOYMENT_COMPLETED" = true ]; then
    exit "$original_exit_code"
  fi

  DEPLOYMENT_ATTEMPT_ACTIVE=false
  if [ "$ROLLBACK_IN_PROGRESS" = true ] || [ "$ROLLBACK_ATTEMPTED" = true ]; then
    exit "$original_exit_code"
  fi

  ROLLBACK_IN_PROGRESS=true
  ROLLBACK_ATTEMPTED=true
  failure_message="Deployment failed during ${DEPLOYMENT_STAGE} for SHA ${GIT_SHA}; rollback is starting."

  if ! printf '%s\n' "$GIT_SHA" > "$FAILED_SHA_FILE"; then
    echo "[warn] failed to write deployment failure state: ${FAILED_SHA_FILE}" >&2
  fi

  if [ "$DEPLOYMENT_FAILED_ALERT_SENT" != true ]; then
    send_alert "deployment_failed" "error" "$failure_message" || true
    DEPLOYMENT_FAILED_ALERT_SENT=true
  fi

  dump_compose_diagnostics || true

  if [ "$ROLLBACK_TARGET_READY" != true ]; then
    echo "Automatic rollback skipped because no safe rollback target was established." >&2
    exit "$original_exit_code"
  fi

  echo "Starting automatic rollback to $(tr -d '[:space:]' < "$PREVIOUS_SHA_FILE")."
  if ./scripts/rollback.sh; then
    echo "Automatic rollback succeeded."
  else
    rollback_exit_code=$?
    echo "Automatic rollback failed with exit code ${rollback_exit_code}." >&2
  fi

  ROLLBACK_IN_PROGRESS=false

  # Preserve the deployment failure even when rollback restores production successfully.
  exit "$original_exit_code"
}

cleanup_legacy_container() {
  local name="$1"
  local container_id
  local project_label

  container_id=$("${DOCKER[@]}" ps -aq --filter "name=^/${name}$" | head -n 1)
  if [ -z "$container_id" ]; then
    return
  fi

  project_label=$("${DOCKER[@]}" inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id" 2>/dev/null || true)
  if [ "$project_label" = "$COMPOSE_PROJECT_NAME" ]; then
    return
  fi

  echo "Removing legacy conflicting container '${name}' from Compose project '${project_label:-none}'."
  "${DOCKER[@]}" rm -f "$container_id"
}

# One-time migration cleanup for containers created by the old hardcoded
# container_name settings or by a different default Compose project name.
# Failure handling starts at the first command that can change the production stack.
# Rollback itself remains guarded until previous.sha contains the known healthy SHA.
DEPLOYMENT_ATTEMPT_ACTIVE=true
trap handle_deployment_failure ERR

DEPLOYMENT_STAGE="legacy container cleanup"
cleanup_legacy_container zero-downtime-nginx
cleanup_legacy_container zero-downtime-frontend
cleanup_legacy_container zero-downtime-backend

send_alert "deployment_started" "info" "Deployment started for SHA ${GIT_SHA}." || true

DEPLOYMENT_STAGE="GHCR login"
if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | "${DOCKER[@]}" login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

DEPLOYMENT_STAGE="pulling deployment images"
"${COMPOSE[@]}" pull

DEPLOYMENT_STAGE="starting deployment services"
"${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60

echo "Restarting nginx to refresh upstream resolution..."
DEPLOYMENT_STAGE="restarting nginx"
"${COMPOSE[@]}" restart nginx

DEPLOYMENT_STAGE="reading Compose service status"
"${COMPOSE[@]}" ps

DEPLOYMENT_STAGE="verifying the deployment"
./scripts/verify-deployment.sh "$VERIFY_APP_URL"

DEPLOYMENT_STAGE="recording verified deployment state"
printf '%s\n' "$GIT_SHA" > "$CURRENT_SHA_FILE"

DEPLOYMENT_COMPLETED=true
DEPLOYMENT_ATTEMPT_ACTIVE=false
trap - ERR

send_alert "deployment_success" "success" "Deployment verified successfully for SHA ${GIT_SHA}." || true
"${DOCKER[@]}" image prune -f || true

echo "Deployment succeeded. Current deployment is now ${GIT_SHA}."
exit 0
