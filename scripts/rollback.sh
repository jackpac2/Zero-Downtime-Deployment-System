#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
COMPOSE_PROJECT_NAME="zero-downtime"
COMPOSE_FILE="compose/docker-compose.prod.yml"
DEPLOY_DIR=".deploy"
CURRENT_SHA_FILE="${DEPLOY_DIR}/current.sha"
PREVIOUS_SHA_FILE="${DEPLOY_DIR}/previous.sha"
ROLLED_BACK_FROM_FILE="${DEPLOY_DIR}/rolled-back-from.sha"

cd "$APP_DIR"

if [ ! -f "$PREVIOUS_SHA_FILE" ]; then
  echo "Rollback target not found: ${PREVIOUS_SHA_FILE}" >&2
  exit 1
fi

ROLLBACK_SHA="$(tr -d '[:space:]' < "$PREVIOUS_SHA_FILE")"

if [ -z "$ROLLBACK_SHA" ]; then
  echo "Rollback target is empty: ${PREVIOUS_SHA_FILE}" >&2
  exit 1
fi

CURRENT_SHA=""
if [ -f "$CURRENT_SHA_FILE" ]; then
  CURRENT_SHA="$(tr -d '[:space:]' < "$CURRENT_SHA_FILE")"
fi

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "Cannot access Docker. Add the deploy user to the docker group or allow passwordless sudo for docker." >&2
  exit 1
fi

COMPOSE=("${DOCKER[@]}" compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE")

print_diagnostics() {
  echo "Rollback failed. Compose service status:"
  "${COMPOSE[@]}" ps || true
  echo "Recent backend logs:"
  "${COMPOSE[@]}" logs --tail=100 backend || true
  echo "Recent nginx logs:"
  "${COMPOSE[@]}" logs --tail=100 nginx || true
}

trap print_diagnostics ERR

export IMAGE_TAG="$ROLLBACK_SHA"

echo "Starting rollback to ${ROLLBACK_SHA}."
if [ -n "$CURRENT_SHA" ]; then
  echo "Current deployment before rollback: ${CURRENT_SHA}"
fi

"${COMPOSE[@]}" pull
"${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60
"${COMPOSE[@]}" ps

printf '%s\n' "$ROLLBACK_SHA" > "$CURRENT_SHA_FILE"

if [ -n "$CURRENT_SHA" ]; then
  printf '%s\n' "$CURRENT_SHA" > "$ROLLED_BACK_FROM_FILE"
fi

echo "Rollback succeeded. Current deployment is now ${ROLLBACK_SHA}."
