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
fi

export IMAGE_TAG="$GIT_SHA"

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

dump_compose_diagnostics() {
  echo "Deployment failed. Compose service status:"
  "${COMPOSE[@]}" ps || true
  echo "Recent backend logs:"
  "${COMPOSE[@]}" logs --tail=100 backend || true
  echo "Recent nginx logs:"
  "${COMPOSE[@]}" logs --tail=100 nginx || true
}

rollback_after_failed_deploy() {
  if [ ! -f "$PREVIOUS_SHA_FILE" ] || [ -z "$(tr -d '[:space:]' < "$PREVIOUS_SHA_FILE")" ]; then
    echo "Rollback cannot run because ${PREVIOUS_SHA_FILE} is missing or empty." >&2
    echo "Current deployment marker remains unchanged." >&2
    return 1
  fi

  echo "Starting automatic rollback to $(tr -d '[:space:]' < "$PREVIOUS_SHA_FILE")."
  if ./scripts/rollback.sh; then
    echo "Rollback command completed. Verifying restored deployment..."
    if ./scripts/verify-deployment.sh "$VERIFY_APP_URL"; then
      echo "Automatic rollback succeeded and verification passed."
      return 0
    fi

    echo "Automatic rollback completed, but rollback verification failed." >&2
    return 1
  fi

  echo "Automatic rollback failed." >&2
  return 1
}

trap dump_compose_diagnostics ERR

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
cleanup_legacy_container zero-downtime-nginx
cleanup_legacy_container zero-downtime-frontend
cleanup_legacy_container zero-downtime-backend

if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | "${DOCKER[@]}" login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

"${COMPOSE[@]}" pull
"${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60

echo "Restarting nginx to refresh upstream resolution..."
"${COMPOSE[@]}" restart nginx

"${COMPOSE[@]}" ps

if ./scripts/verify-deployment.sh "$VERIFY_APP_URL"; then
  printf '%s\n' "$GIT_SHA" > "$CURRENT_SHA_FILE"
  "${DOCKER[@]}" image prune -f || true

  echo "Deployment succeeded. Current deployment is now ${GIT_SHA}."
  exit 0
fi

printf '%s\n' "$GIT_SHA" > "$FAILED_SHA_FILE"
echo "Deployment verification failed for ${GIT_SHA}." >&2
dump_compose_diagnostics

rollback_after_failed_deploy || true
exit 1
