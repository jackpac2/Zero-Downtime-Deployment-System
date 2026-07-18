#!/usr/bin/env bash

set -euo pipefail

# These arrays remain safely empty if preflight fails before Compose commands
# are assembled; rollback diagnostics must work at every failure boundary.
LEGACY_COMPOSE=()
APP_COMPOSE=()
ROUTER_COMPOSE=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/deployment-common.sh
source "${SCRIPT_DIR}/lib/deployment-common.sh"
# shellcheck source=scripts/lib/stable-router-migration-transaction.sh
source "${SCRIPT_DIR}/lib/stable-router-migration-transaction.sh"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <40-character-git-sha>" >&2
  exit 1
fi

validate_deployment_sha "${1-}" "Migration SHA" || exit 1

MIGRATION_SHA="${1,,}"
APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
BRANCH="Main"
DEPLOY_DIR="${APP_DIR}/.deploy"
CURRENT_SHA_FILE="${DEPLOY_DIR}/current.sha"
PREVIOUS_SHA_FILE="${DEPLOY_DIR}/previous.sha"
TOPOLOGY_FILE="${DEPLOY_DIR}/topology"
LEGACY_PROJECT="zero-downtime"
APP_PROJECT="zero-downtime-app"
ROUTER_PROJECT="zero-downtime-router"
LEGACY_FILE="compose/docker-compose.prod.yml"
APP_FILE="compose/docker-compose.app.yml"
ROUTER_FILE="compose/docker-compose.router.yml"
ROUTER_NETWORK="zero-downtime-router"
NETWORK_CREATED=false
LEGACY_SHA=""
CUTOVER_STARTED_AT=""
VERIFY_APP_URL=""
DOCKER=()

cd "$APP_DIR"
ensure_deployment_state_dir "$DEPLOY_DIR"
acquire_deployment_lock "$DEPLOY_DIR"

if [ "${MIGRATION_ASSET_SHA:-}" != "$MIGRATION_SHA" ]; then
  prepare_exact_deployment_commit "$APP_DIR" "$MIGRATION_SHA" "$BRANCH"
  if [ ! -x "${APP_DIR}/scripts/migrate-to-stable-router.sh" ]; then
    echo "Requested commit does not contain stable-router migration tooling: ${MIGRATION_SHA}" >&2
    exit 1
  fi
  export MIGRATION_ASSET_SHA="$MIGRATION_SHA"
  exec "${APP_DIR}/scripts/migrate-to-stable-router.sh" "$MIGRATION_SHA"
fi

verify_exact_deployment_commit "$APP_DIR" "$MIGRATION_SHA" "$BRANCH"
export IMAGE_TAG="$MIGRATION_SHA"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//"/\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

migration_notify() {
  local event="$1"
  local status="$2"
  local message="$3"
  local payload

  payload=$(printf '{"project":"%s","environment":"production","sha":"%s","appUrl":"%s","event":"%s","status":"%s","message":"%s","phase":"%s"}' \
    "$(json_escape "Zero-Downtime Deployment Challenge")" \
    "$(json_escape "$MIGRATION_SHA")" \
    "$(json_escape "$VERIFY_APP_URL")" \
    "$(json_escape "$event")" \
    "$(json_escape "$status")" \
    "$(json_escape "$message")" \
    "$(json_escape "$MIGRATION_PHASE")")

  if ! curl -fsS -X POST http://127.0.0.1:9001/notify \
    -H 'Content-Type: application/json' --data "$payload" >/dev/null; then
    echo "[warn] migration notification failed: ${event}" >&2
  fi
  return 0
}

select_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
  else
    echo "Migration preflight failed: Docker is unavailable to the deploy user." >&2
    return 1
  fi
}

compose_arrays() {
  LEGACY_COMPOSE=("${DOCKER[@]}" compose -p "$LEGACY_PROJECT" -f "$LEGACY_FILE")
  APP_COMPOSE=("${DOCKER[@]}" compose -p "$APP_PROJECT" -f "$APP_FILE")
  ROUTER_COMPOSE=("${DOCKER[@]}" compose -p "$ROUTER_PROJECT" -f "$ROUTER_FILE")
}

assert_project_owns_port() {
  local port="$1"
  local expected_project="$2"
  local projects

  projects=$("${DOCKER[@]}" ps --filter "publish=${port}" --format '{{.Label "com.docker.compose.project"}}' | sort -u)
  if [ -z "$projects" ]; then
    echo "Migration preflight failed: no Docker container owns required legacy port ${port}." >&2
    return 1
  fi

  while IFS= read -r project; do
    if [ "$project" != "$expected_project" ]; then
      echo "Migration preflight failed: port ${port} is owned by unexpected project '${project:-none}'." >&2
      return 1
    fi
  done <<< "$projects"
}

assert_no_project_containers() {
  local name="$1"
  shift
  if [ -n "$("$@" ps -q)" ]; then
    echo "Migration preflight failed: prepared project ${name} already has containers." >&2
    return 1
  fi
}

verify_service_revision() {
  local service="$1"
  shift
  local image_id
  local revision

  image_id=$("$@" images -q "$service" | head -n 1)
  if [ -z "$image_id" ]; then
    echo "Revision verification failed: no image found for ${service}." >&2
    return 1
  fi
  revision=$("${DOCKER[@]}" image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id" 2>/dev/null || true)
  if [ "${revision,,}" != "$MIGRATION_SHA" ]; then
    echo "Revision verification failed for ${service}: expected ${MIGRATION_SHA}, found ${revision:-missing}." >&2
    return 1
  fi
}

migration_preflight() {
  local available_kb
  local network_driver
  local network_scope

  for file in "$LEGACY_FILE" "$APP_FILE" "$ROUTER_FILE" nginx/router.conf scripts/verify-deployment.sh; do
    [ -f "$file" ] || { echo "Migration preflight failed: missing ${file}." >&2; return 1; }
  done

  LEGACY_SHA=$(read_deployment_sha_file "$CURRENT_SHA_FILE" "Current deployment SHA") || return 1
  if [ "$LEGACY_SHA" != "$MIGRATION_SHA" ]; then
    echo "Migration preflight failed: current.sha (${LEGACY_SHA}) does not match requested SHA (${MIGRATION_SHA})." >&2
    return 1
  fi

  if [ -n "${APP_URL:-}" ]; then
    VERIFY_APP_URL="${APP_URL%/}"
  elif [ -n "${EC2_HOST:-}" ]; then
    VERIFY_APP_URL="http://${EC2_HOST}"
  else
    echo "Migration preflight failed: APP_URL or EC2_HOST is required." >&2
    return 1
  fi

  select_docker || return 1
  compose_arrays
  "${DOCKER[@]}" compose version >/dev/null 2>&1 || return 1
  "${DOCKER[@]}" compose up --help | grep -q -- '--wait' || {
    echo "Migration preflight failed: Docker Compose does not support up --wait." >&2
    return 1
  }

  "${LEGACY_COMPOSE[@]}" config --quiet || return 1
  "${APP_COMPOSE[@]}" config --quiet || return 1
  "${ROUTER_COMPOSE[@]}" config --quiet || return 1
  "${DOCKER[@]}" run --rm -v "${APP_DIR}/nginx/router.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine nginx -t

  [ -n "$("${LEGACY_COMPOSE[@]}" ps -q)" ] || {
    echo "Migration preflight failed: legacy project is not running." >&2
    return 1
  }
  assert_no_project_containers "$APP_PROJECT" "${APP_COMPOSE[@]}" || return 1
  assert_no_project_containers "$ROUTER_PROJECT" "${ROUTER_COMPOSE[@]}" || return 1
  assert_project_owns_port 80 "$LEGACY_PROJECT" || return 1
  assert_project_owns_port 9001 "$LEGACY_PROJECT" || return 1

  if "${DOCKER[@]}" network inspect "$ROUTER_NETWORK" >/dev/null 2>&1; then
    network_driver=$("${DOCKER[@]}" network inspect -f '{{.Driver}}' "$ROUTER_NETWORK")
    network_scope=$("${DOCKER[@]}" network inspect -f '{{.Scope}}' "$ROUTER_NETWORK")
    if [ "$network_driver" != bridge ] || [ "$network_scope" != local ]; then
      echo "Migration preflight failed: existing ${ROUTER_NETWORK} network is incompatible." >&2
      return 1
    fi
  fi

  available_kb=$(df -Pk "$APP_DIR" | awk 'NR == 2 { print $4 }')
  if [ -z "$available_kb" ] || [ "$available_kb" -lt 1048576 ]; then
    echo "Migration preflight failed: at least 1 GiB of free disk space is required." >&2
    return 1
  fi
}

migration_prepare_network() {
  if "${DOCKER[@]}" network inspect "$ROUTER_NETWORK" >/dev/null 2>&1; then
    echo "Using existing operator-managed network: ${ROUTER_NETWORK}"
    return 0
  fi
  "${DOCKER[@]}" network create --driver bridge "$ROUTER_NETWORK" >/dev/null
  NETWORK_CREATED=true
  echo "Created migration network: ${ROUTER_NETWORK}"
}

migration_pull_images() {
  "${APP_COMPOSE[@]}" pull
  "${ROUTER_COMPOSE[@]}" pull
}

migration_start_application() {
  "${APP_COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60
  "${APP_COMPOSE[@]}" ps
}

migration_verify_application() {
  "${APP_COMPOSE[@]}" exec -T frontend wget -q -O /dev/null http://127.0.0.1/
  "${APP_COMPOSE[@]}" exec -T backend node -e "require('http').get('http://127.0.0.1:3001/api/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
  "${APP_COMPOSE[@]}" exec -T frontend wget -q -O /dev/null http://backend:3001/api/health
  verify_service_revision frontend "${APP_COMPOSE[@]}"
  verify_service_revision backend "${APP_COMPOSE[@]}"
}

migration_stop_legacy() {
  CUTOVER_STARTED_AT=$(date +%s)
  "${LEGACY_COMPOSE[@]}" stop
}

migration_verify_cutover_ports() {
  if [ -n "$("${DOCKER[@]}" ps --filter publish=80 -q)" ] || [ -n "$("${DOCKER[@]}" ps --filter publish=9001 -q)" ]; then
    echo "Cutover aborted: ports 80 or 9001 remain owned after legacy shutdown." >&2
    return 1
  fi
}

migration_start_router() {
  "${ROUTER_COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60
  "${ROUTER_COMPOSE[@]}" ps
}

migration_verify_router() {
  "${ROUTER_COMPOSE[@]}" exec -T nginx wget -q -O /dev/null http://127.0.0.1/router-health
  curl -fsS http://127.0.0.1:9001/health >/dev/null
  verify_service_revision notifier "${ROUTER_COMPOSE[@]}"
  verify_service_revision frontend "${APP_COMPOSE[@]}"
  verify_service_revision backend "${APP_COMPOSE[@]}"
}

migration_verify_public() {
  ./scripts/verify-deployment.sh "$VERIFY_APP_URL"
  curl -fsS "${VERIFY_APP_URL}/router-health" >/dev/null
}

migration_commit_state() {
  local temporary_file="${TOPOLOGY_FILE}.tmp.$$"
  printf '%s\n' stable-router > "$temporary_file"
  mv -f "$temporary_file" "$TOPOLOGY_FILE"
  [ "$(<"$TOPOLOGY_FILE")" = stable-router ]
}

migration_capture_diagnostics() {
  local failed_phase="$1"
  echo "Migration failed during ${failed_phase}. Prepared project diagnostics:" >&2
  "${APP_COMPOSE[@]}" ps || true
  "${APP_COMPOSE[@]}" logs --tail=100 frontend backend || true
  "${ROUTER_COMPOSE[@]}" ps || true
  "${ROUTER_COMPOSE[@]}" logs --tail=100 nginx notifier || true
}

remove_created_network_if_safe() {
  local attached
  if [ "$NETWORK_CREATED" != true ]; then
    return 0
  fi
  attached=$("${DOCKER[@]}" network inspect -f '{{len .Containers}}' "$ROUTER_NETWORK" 2>/dev/null || echo 1)
  if [ "$attached" = 0 ]; then
    "${DOCKER[@]}" network rm "$ROUTER_NETWORK" >/dev/null || true
  fi
}

migration_cleanup_before_cutover() {
  "${ROUTER_COMPOSE[@]}" down --remove-orphans || true
  "${APP_COMPOSE[@]}" down --remove-orphans || true
  remove_created_network_if_safe
}

migration_stop_new_router() {
  "${ROUTER_COMPOSE[@]}" down --remove-orphans || true
}

migration_stop_new_application() {
  "${APP_COMPOSE[@]}" down --remove-orphans || true
}

migration_restore_legacy() {
  validate_deployment_sha "$LEGACY_SHA" "Legacy restoration SHA" || return 1
  export IMAGE_TAG="$LEGACY_SHA"
  "${LEGACY_COMPOSE[@]}" pull
  "${LEGACY_COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60
  "${LEGACY_COMPOSE[@]}" restart nginx
}

migration_verify_restored_legacy() {
  ./scripts/verify-deployment.sh "$VERIFY_APP_URL"
}

migration_print_manual_recovery() {
  cat >&2 <<EOF
MANUAL RECOVERY REQUIRED
cd ${APP_DIR}
export IMAGE_TAG=${LEGACY_SHA}
docker compose -p ${LEGACY_PROJECT} -f ${LEGACY_FILE} up -d --remove-orphans --wait --wait-timeout 60
docker compose -p ${LEGACY_PROJECT} -f ${LEGACY_FILE} restart nginx
./scripts/verify-deployment.sh ${VERIFY_APP_URL}
EOF
}

migration_report_success() {
  local completed_at
  completed_at=$(date +%s)
  echo "Stable-router migration succeeded for ${MIGRATION_SHA}."
  if [ -n "$CUTOVER_STARTED_AT" ]; then
    echo "Measured router transition and verification window: $((completed_at - CUTOVER_STARTED_AT)) seconds."
  fi
  echo "Topology marker committed: ${TOPOLOGY_FILE}"
}

run_stable_router_migration
