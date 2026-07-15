#!/usr/bin/env bash

# Shared validation, locking, and repository preparation for production operations.

deployment_error() {
  printf '%s\n' "$*" >&2
}

validate_deployment_sha() {
  local sha="${1-}"
  local label="${2:-Deployment SHA}"

  if [ -z "$sha" ]; then
    deployment_error "${label} is required. Expected exactly 40 hexadecimal characters."
    return 1
  fi

  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    deployment_error "${label} is invalid. Expected exactly 40 hexadecimal characters."
    return 1
  fi
}

read_deployment_sha_file() {
  local file="$1"
  local label="${2:-Deployment SHA}"
  local sha

  if [ ! -f "$file" ]; then
    deployment_error "${label} file not found: ${file}"
    return 1
  fi

  sha="$(<"$file")"
  validate_deployment_sha "$sha" "$label" || return 1
  printf '%s\n' "${sha,,}"
}

ensure_deployment_state_dir() {
  local deploy_dir="$1"

  if ! mkdir -p -- "$deploy_dir"; then
    deployment_error "Cannot create deployment state directory: ${deploy_dir}"
    return 1
  fi

  if [ ! -d "$deploy_dir" ] || [ ! -w "$deploy_dir" ]; then
    deployment_error "Deployment state directory is not writable: ${deploy_dir}"
    return 1
  fi
}

acquire_deployment_lock() {
  local deploy_dir="$1"
  local lock_file
  local actual_lock_file

  if ! command -v flock >/dev/null 2>&1; then
    deployment_error "Cannot protect the deployment: Linux flock is not installed."
    return 1
  fi

  lock_file="$(cd "$deploy_dir" && pwd -P)/deployment.lock"

  if [ -n "${DEPLOY_LOCK_FD:-}" ]; then
    if [[ ! "$DEPLOY_LOCK_FD" =~ ^[0-9]+$ ]] || [ ! -e "/proc/$$/fd/${DEPLOY_LOCK_FD}" ]; then
      deployment_error "Inherited deployment lock descriptor is invalid."
      return 1
    fi

    actual_lock_file="$(readlink -f "/proc/$$/fd/${DEPLOY_LOCK_FD}")"
    if [ "$actual_lock_file" != "$lock_file" ]; then
      deployment_error "Inherited deployment lock does not reference ${lock_file}."
      return 1
    fi

    if ! flock -n "$DEPLOY_LOCK_FD"; then
      deployment_error "Cannot confirm the inherited deployment lock: ${lock_file}"
      return 1
    fi

    return 0
  fi

  DEPLOY_LOCK_FD=200
  if ! exec 200>"$lock_file"; then
    deployment_error "Cannot open deployment lock file: ${lock_file}"
    unset DEPLOY_LOCK_FD
    return 1
  fi

  if ! flock -n "$DEPLOY_LOCK_FD"; then
    deployment_error "Another deployment or rollback is already running. Lock: ${lock_file}"
    exec 200>&-
    unset DEPLOY_LOCK_FD
    return 1
  fi

  export DEPLOY_LOCK_FD
}

verify_exact_deployment_commit() {
  local repo_dir="$1"
  local sha="$2"
  local branch="$3"
  local actual_sha

  validate_deployment_sha "$sha" "Requested deployment SHA" || return 1

  if [ ! -d "$repo_dir/.git" ]; then
    deployment_error "Deployment repository is missing or invalid: ${repo_dir}"
    return 1
  fi

  if ! git -C "$repo_dir" rev-parse --verify "refs/remotes/origin/${branch}^{commit}" >/dev/null 2>&1; then
    deployment_error "Remote deployment branch is unavailable: origin/${branch}"
    return 1
  fi

  if ! git -C "$repo_dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    deployment_error "Requested deployment commit does not exist: ${sha}"
    return 1
  fi

  if ! git -C "$repo_dir" merge-base --is-ancestor "$sha" "origin/${branch}"; then
    deployment_error "Requested deployment commit is not part of origin/${branch}: ${sha}"
    return 1
  fi

  actual_sha="$(git -C "$repo_dir" rev-parse HEAD)"
  if [ "$actual_sha" != "${sha,,}" ]; then
    deployment_error "Deployment checkout mismatch. Expected ${sha,,}, found ${actual_sha}."
    return 1
  fi
}

prepare_exact_deployment_commit() {
  local repo_dir="$1"
  local sha="$2"
  local branch="$3"
  local original_sha
  local dirty_files

  validate_deployment_sha "$sha" "Requested deployment SHA" || return 1

  if [ ! -d "$repo_dir/.git" ]; then
    deployment_error "Deployment repository is missing or invalid: ${repo_dir}"
    return 1
  fi

  git -C "$repo_dir" config core.fileMode false

  if ! git -C "$repo_dir" fetch --no-tags origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
    deployment_error "Failed to fetch origin/${branch}."
    return 1
  fi

  if ! git -C "$repo_dir" rev-parse --verify "refs/remotes/origin/${branch}^{commit}" >/dev/null 2>&1; then
    deployment_error "Remote deployment branch is unavailable after fetch: origin/${branch}"
    return 1
  fi

  if ! git -C "$repo_dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    deployment_error "Requested deployment commit does not exist after fetch: ${sha}"
    return 1
  fi

  if ! git -C "$repo_dir" merge-base --is-ancestor "$sha" "origin/${branch}"; then
    deployment_error "Requested deployment commit is not part of origin/${branch}: ${sha}"
    return 1
  fi

  dirty_files="$(git -C "$repo_dir" status --porcelain --untracked-files=no)"
  if [ -n "$dirty_files" ]; then
    deployment_error "Deployment checkout has tracked local changes; refusing to replace them."
    return 1
  fi

  original_sha="$(git -C "$repo_dir" rev-parse HEAD)"
  if [ "$original_sha" != "${sha,,}" ]; then
    if ! git -C "$repo_dir" checkout --detach "$sha"; then
      deployment_error "Failed to check out requested deployment commit: ${sha}"
      return 1
    fi
  fi

  if ! verify_exact_deployment_commit "$repo_dir" "$sha" "$branch"; then
    if [ "$original_sha" != "${sha,,}" ]; then
      git -C "$repo_dir" checkout --detach "$original_sha" >/dev/null 2>&1 || true
    fi
    return 1
  fi
}
