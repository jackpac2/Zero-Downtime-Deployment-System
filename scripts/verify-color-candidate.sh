#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=scripts/lib/deployment-common.sh
source "${SCRIPT_DIR}/lib/deployment-common.sh"

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <blue|green> <expected-sha>" >&2
  exit 1
fi

DEPLOY_COLOR="$1"
EXPECTED_SHA="$2"
APP_COMPOSE_FILE="compose/docker-compose.app.yml"
ROUTER_NETWORK="zero-downtime-router"
VERIFY_IMAGE="${CANDIDATE_VERIFY_IMAGE:-nginx:1.27-alpine}"

validate_deployment_color "$DEPLOY_COLOR" "Candidate deployment color" || exit 1
validate_deployment_sha "$EXPECTED_SHA" "Candidate deployment SHA" || exit 1
EXPECTED_SHA="${EXPECTED_SHA,,}"
PROJECT_NAME="$(deployment_project_for_color "$DEPLOY_COLOR")"
FRONTEND_ALIAS="$(frontend_alias_for_color "$DEPLOY_COLOR")"
BACKEND_ALIAS="$(backend_alias_for_color "$DEPLOY_COLOR")"

fail_candidate_verification() {
  echo "Candidate verification failed: $*" >&2
  exit 1
}

cd "$ROOT_DIR"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  fail_candidate_verification "Docker is unavailable to the current user."
fi

export DEPLOY_COLOR EXPECTED_SHA
export IMAGE_TAG="$EXPECTED_SHA"
COMPOSE=("${DOCKER[@]}" compose -p "$PROJECT_NAME" -f "$APP_COMPOSE_FILE")

"${COMPOSE[@]}" config --quiet || \
  fail_candidate_verification "Compose configuration is invalid for ${PROJECT_NAME}."

if [ -z "$("${DOCKER[@]}" ps -aq --filter "label=com.docker.compose.project=${PROJECT_NAME}")" ]; then
  fail_candidate_verification "Compose project ${PROJECT_NAME} does not exist."
fi

running_services="$("${DOCKER[@]}" ps \
  --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
  --format '{{.Label "com.docker.compose.service"}}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$running_services" != "backend frontend" ]; then
  fail_candidate_verification \
    "expected running services 'backend frontend' for ${PROJECT_NAME}, found '${running_services:-none}'."
fi

container_for_service() {
  local service="$1"
  local container_ids
  container_ids="$("${DOCKER[@]}" ps -q \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=${service}")"
  if [ "$(printf '%s\n' "$container_ids" | sed '/^$/d' | wc -l | tr -d '[:space:]')" != 1 ]; then
    fail_candidate_verification \
      "expected exactly one running ${service} container for ${PROJECT_NAME}."
  fi
  printf '%s\n' "$container_ids"
}

verify_container() {
  local service="$1"
  local expected_alias="$2"
  local container_id
  local image_id
  local revision
  local networks
  local aliases

  container_id="$(container_for_service "$service")"
  image_id="$("${DOCKER[@]}" inspect -f '{{.Image}}' "$container_id")"
  revision="$("${DOCKER[@]}" image inspect \
    -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id")"
  if [ "${revision,,}" != "$EXPECTED_SHA" ]; then
    fail_candidate_verification \
      "${PROJECT_NAME}/${service} expected revision ${EXPECTED_SHA}, found ${revision:-missing}."
  fi

  networks="$("${DOCKER[@]}" inspect \
    -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_id")"
  if ! grep -Fxq "$ROUTER_NETWORK" <<<"$networks"; then
    fail_candidate_verification \
      "${PROJECT_NAME}/${service} is not attached to ${ROUTER_NETWORK}."
  fi

  aliases="$("${DOCKER[@]}" inspect \
    -f '{{range (index .NetworkSettings.Networks "zero-downtime-router").Aliases}}{{println .}}{{end}}' \
    "$container_id")"
  if ! grep -Fxq "$expected_alias" <<<"$aliases"; then
    fail_candidate_verification \
      "${PROJECT_NAME}/${service} is missing router alias ${expected_alias}."
  fi
}

verify_container frontend "$FRONTEND_ALIAS"
verify_container backend "$BACKEND_ALIAS"

"${DOCKER[@]}" run --rm --network "$ROUTER_NETWORK" "$VERIFY_IMAGE" \
  sh -ec 'wget -q -O /dev/null "http://$1/"; wget -q -O /dev/null "http://$2:3001/api/health"' \
  _ "$FRONTEND_ALIAS" "$BACKEND_ALIAS" || \
  fail_candidate_verification "network-internal frontend or backend health check failed."

printf 'Candidate verification passed for %s at %s.\n' "$PROJECT_NAME" "$EXPECTED_SHA"
