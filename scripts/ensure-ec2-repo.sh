#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <app-dir> <repo-url> <branch>" >&2
  exit 1
fi

APP_DIR="$1"
REPO_URL="$2"
BRANCH="$3"

repository_hostname() {
  local repo_url="$1"
  local authority

  case "$repo_url" in
    *://*)
      authority="${repo_url#*://}"
      authority="${authority%%/*}"
      authority="${authority##*@}"
      printf '%s\n' "${authority%%:*}"
      ;;
    *@*:*)
      authority="${repo_url%%:*}"
      printf '%s\n' "${authority##*@}"
      ;;
    *)
      printf '%s\n' local-path
      ;;
  esac
}

is_valid_git_repository() {
  [ -d "$APP_DIR/.git" ] && git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

redact_clone_output() {
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1[credentials-redacted]@#g' \
    -e 's#(ssh://)[^/@[:space:]]+@#\1[user-redacted]@#g'
}

git --version

if is_valid_git_repository; then
  # Existing deployment checkouts are deliberately left untouched here.
  # deploy.sh acquires the shared production lock before fetching, validating,
  # and checking out the exact requested commit.
  exit 0
fi

if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]; then
  echo "App directory exists but is not a Git repository: $APP_DIR" >&2
  echo "Move or remove that directory, then rerun the deployment." >&2
  exit 1
fi

mkdir -p "$(dirname "$APP_DIR")"
repository_host="$(repository_hostname "$REPO_URL")"
printf 'Repository host: %s\n' "$repository_host"
printf 'Cloning branch %s into %s...\n' "$BRANCH" "$APP_DIR"

app_dir_existed=false
if [ -e "$APP_DIR" ]; then
  app_dir_existed=true
fi

set +e
git clone --progress --branch "$BRANCH" -- "$REPO_URL" "$APP_DIR" 2>&1 \
  | redact_clone_output >&2
clone_status="${PIPESTATUS[0]}"
set -e

if [ "$clone_status" -eq 0 ]; then
  printf 'Repository clone completed successfully.\n'
  exit 0
fi

printf 'Repository clone failed with exit status %s.\n' "$clone_status" >&2
if [ "$app_dir_existed" = false ] && [ -e "$APP_DIR" ] && ! is_valid_git_repository; then
  printf 'Removing incomplete clone directory created by this attempt: %s\n' "$APP_DIR" >&2
  rm -rf -- "$APP_DIR"
fi

exit "$clone_status"
