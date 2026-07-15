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
  # Existing deployment checkouts are deliberately left untouched here.
  # deploy.sh acquires the shared production lock before fetching, validating,
  # and checking out the exact requested commit.
  git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null
  exit 0
fi

if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
  echo "App directory exists but is not a Git repository: $APP_DIR" >&2
  echo "Move or remove that directory, then rerun the deployment." >&2
  exit 1
fi

mkdir -p "$(dirname "$APP_DIR")"
git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
