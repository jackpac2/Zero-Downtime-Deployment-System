#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <git-sha>" >&2
  exit 1
fi

GIT_SHA="$1"
APP_DIR="/home/ubuntu/Zero-Downtime-Deployment-System"
BRANCH="Main"

cd "$APP_DIR"

git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

export IMAGE_TAG="$GIT_SHA"

mkdir -p .deploy
if [ -f .deploy/current.sha ]; then
  cp .deploy/current.sha .deploy/previous.sha
fi

if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

docker compose -f compose/docker-compose.prod.yml pull
docker compose -f compose/docker-compose.prod.yml up -d

docker image prune -f
docker ps

printf '%s\n' "$GIT_SHA" > .deploy/current.sha
