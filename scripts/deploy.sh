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

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "Cannot access Docker. Add the deploy user to the docker group or allow passwordless sudo for docker." >&2
  exit 1
fi

if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | "${DOCKER[@]}" login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

"${DOCKER[@]}" compose -f compose/docker-compose.prod.yml pull
"${DOCKER[@]}" compose -f compose/docker-compose.prod.yml up -d

"${DOCKER[@]}" image prune -f
"${DOCKER[@]}" ps

printf '%s\n' "$GIT_SHA" > .deploy/current.sha
