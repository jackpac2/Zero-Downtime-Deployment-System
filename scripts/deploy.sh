#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <git-sha>" >&2
  exit 1
fi

GIT_SHA="$1"
APP_DIR="/home/ubuntu/Zero-Downtime-Deployment-System"
BRANCH="Main"
COMPOSE_PROJECT_NAME="zero-downtime"
COMPOSE_FILE="compose/docker-compose.prod.yml"

cd "$APP_DIR"

git config core.fileMode false
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

export IMAGE_TAG="$GIT_SHA"

if [ -z "${GIT_SHA:-}" ]; then
  echo "Usage: ./scripts/deploy.sh <git-sha>"
  exit 1
fi

mkdir -p .deploy

if [ -f .deploy/current.sha ]; then
  cp .deploy/current.sha .deploy/previous.sha
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

dump_compose_diagnostics() {
  echo "Deployment failed. Compose service status:"
  "${COMPOSE[@]}" ps || true
  echo "Recent backend logs:"
  "${COMPOSE[@]}" logs --tail=100 backend || true
  echo "Recent nginx logs:"
  "${COMPOSE[@]}" logs --tail=100 nginx || true
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
"${COMPOSE[@]}" ps

printf '%s\n' "$GIT_SHA" > .deploy/current.sha

"${DOCKER[@]}" image prune -f || true
