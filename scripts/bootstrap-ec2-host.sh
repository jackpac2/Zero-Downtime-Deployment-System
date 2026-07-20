#!/usr/bin/env bash

set -euo pipefail

# This helper only prepares an Ubuntu host. Deployment, exact-commit handling,
# locking, Compose orchestration, and migration remain owned by their existing
# scripts.

TEST_MODE="${BOOTSTRAP_TEST_MODE:-false}"
ACTION_LOG="${BOOTSTRAP_ACTION_LOG:-}"
MISSING_ITEMS=" ${BOOTSTRAP_MISSING_ITEMS:-} "
DOCKER_GROUP_CHANGED=false

record_action() {
  if [ -n "$ACTION_LOG" ]; then
    printf '%s\n' "$*" >> "$ACTION_LOG"
  fi
}

item_is_missing() {
  [[ "$MISSING_ITEMS" == *" $1 "* ]]
}

command_available() {
  if [ "$TEST_MODE" = true ]; then
    ! item_is_missing "$1"
  else
    command -v "$1" >/dev/null 2>&1
  fi
}

package_installed() {
  if [ "$TEST_MODE" = true ]; then
    ! item_is_missing "$1"
  else
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
  fi
}

docker_compose_available() {
  if [ "$TEST_MODE" = true ]; then
    ! item_is_missing docker-compose
  else
    docker compose version >/dev/null 2>&1
  fi
}

docker_works_without_sudo() {
  if [ "$TEST_MODE" = true ]; then
    [ "${BOOTSTRAP_DOCKER_INFO_WORKS:-true}" = true ]
  else
    docker info >/dev/null 2>&1
  fi
}

run_privileged() {
  record_action "sudo $*"
  if [ "$TEST_MODE" = true ]; then
    if [ "${BOOTSTRAP_PACKAGE_INSTALL_FAIL:-false}" = true ] && [[ " $* " == *" apt-get install "* ]]; then
      return 1
    fi
    return 0
  fi
  sudo "$@"
}

apt_update() {
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_install() {
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

configure_docker_repository() {
  local codename
  local architecture
  local key_file=""

  if [ "$TEST_MODE" = true ]; then
    codename=noble
    architecture=amd64
    record_action "configure official Docker apt repository ${codename} ${architecture}"
    return 0
  fi

  # shellcheck source=/etc/os-release
  source /etc/os-release
  if [ "${ID:-}" != ubuntu ] || [ -z "${VERSION_CODENAME:-}" ]; then
    echo "EC2 bootstrap supports Ubuntu with a VERSION_CODENAME value." >&2
    return 1
  fi

  codename="$VERSION_CODENAME"
  architecture="$(dpkg --print-architecture)"
  key_file="$(mktemp)"
  trap 'rm -f -- "$key_file"' RETURN

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_file"
  run_privileged install -m 0755 -d /etc/apt/keyrings
  run_privileged install -m 0644 "$key_file" /etc/apt/keyrings/docker.asc
  printf '%s\n' \
    "Types: deb" \
    "URIs: https://download.docker.com/linux/ubuntu" \
    "Suites: ${codename}" \
    "Components: stable" \
    "Architectures: ${architecture}" \
    "Signed-By: /etc/apt/keyrings/docker.asc" | \
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  trap - RETURN
  rm -f -- "$key_file"
}

verify_version() {
  local name="$1"
  shift
  record_action "verify ${name}"
  if [ "$TEST_MODE" = true ]; then
    if item_is_missing "verify-${name}"; then
      echo "EC2 bootstrap verification failed: ${name} is unavailable." >&2
      return 1
    fi
    return 0
  fi
  "$@"
}

base_packages=()
docker_packages=()
installation_required=false

command_available git || base_packages+=(git)
command_available curl || base_packages+=(curl)
package_installed ca-certificates || base_packages+=(ca-certificates)
command_available gpg || base_packages+=(gnupg)
command_available flock || base_packages+=(util-linux)

docker_missing=false
compose_missing=false
command_available docker || docker_missing=true
if [ "$docker_missing" = true ] || ! docker_compose_available; then
  compose_missing=true
fi

if [ "${#base_packages[@]}" -gt 0 ] || [ "$docker_missing" = true ] || [ "$compose_missing" = true ]; then
  installation_required=true
fi

if [ "$installation_required" = true ]; then
  apt_update
fi

if [ "${#base_packages[@]}" -gt 0 ]; then
  apt_install "${base_packages[@]}"
fi

if [ "$docker_missing" = true ] || [ "$compose_missing" = true ]; then
  configure_docker_repository
  apt_update

  if [ "$docker_missing" = true ]; then
    docker_packages+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
  fi
  if [ "$compose_missing" = true ]; then
    docker_packages+=(docker-compose-plugin)
  fi
  apt_install "${docker_packages[@]}"
fi

run_privileged systemctl enable --now docker
run_privileged groupadd -f docker

if docker_works_without_sudo; then
  user_in_docker_group=true
elif [ "$TEST_MODE" = true ]; then
  user_in_docker_group="${BOOTSTRAP_USER_IN_DOCKER_GROUP:-false}"
  deployment_user="${BOOTSTRAP_DEPLOYMENT_USER:-ubuntu}"
else
  deployment_user="$(id -un)"
  if id -nG "$deployment_user" | tr ' ' '\n' | grep -qx docker; then
    user_in_docker_group=true
  else
    user_in_docker_group=false
  fi
fi

if [ "$TEST_MODE" != true ]; then
  deployment_user="$(id -un)"
fi

if [ "$user_in_docker_group" != true ]; then
  run_privileged usermod -aG docker "$deployment_user"
  DOCKER_GROUP_CHANGED=true
fi

verify_version git git --version
verify_version curl curl --version
verify_version flock flock --version
verify_version docker docker --version
verify_version docker-compose docker compose version

if [ "$TEST_MODE" != true ]; then
  if docker_works_without_sudo; then
    echo "Docker already works without sudo for ${deployment_user}."
  else
    sudo docker info >/dev/null
    echo "Docker is running; a fresh SSH session is required for non-sudo access."
  fi
fi

echo "EC2 prerequisite bootstrap completed."
echo "Docker group membership changed: ${DOCKER_GROUP_CHANGED}"
