#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <app-dir> <repo-url> <branch>" >&2
  exit 1
fi

APP_DIR="$1"
REPO_URL="$2"
BRANCH="$3"

if [ -d "$APP_DIR/.git" ]; then
  cd "$APP_DIR"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
  exit 0
fi

if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
  echo "App directory exists but is not a Git repository: $APP_DIR" >&2
  echo "Move or remove that directory, then rerun the deployment." >&2
  exit 1
fi

mkdir -p "$(dirname "$APP_DIR")"
git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
