#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/deployment-common.sh"
source "${SCRIPT_DIR}/lib/router-switch.sh"
[ "$#" -eq 1 ] || { echo "Usage: $0 <40-character-git-sha>" >&2; exit 1; }
validate_deployment_sha "${1-}" "Blue/Green deployment SHA" || exit 1
DEPLOY_SHA="${1,,}"
APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
DEPLOY_DIR="${APP_DIR}/.deploy"
APP_FILE=compose/docker-compose.app.yml
LEGACY_FILE=compose/docker-compose.app-legacy.yml
ROUTER_FILE=compose/docker-compose.router.yml
ROUTER_CONFIG="${APP_DIR}/nginx/router.conf"
ROUTER_RENDERER="${APP_DIR}/scripts/render-router-config.sh"
CURRENT_FILE="${DEPLOY_DIR}/current.sha"; PREVIOUS_FILE="${DEPLOY_DIR}/previous.sha"
ACTIVE_FILE="${DEPLOY_DIR}/active-color"; CANDIDATE_FILE="${DEPLOY_DIR}/candidate-color"
STATE_SNAPSHOT=""; STATE_COMMIT_STARTED=false; FIRST_ACTIVATION=false
ACTIVE_COLOR=""; CANDIDATE_COLOR=""; OLD_CURRENT_SHA=""
DOCKER=(); ROUTER_COMPOSE=(); CANDIDATE_COMPOSE=()
cd "$APP_DIR"
ensure_deployment_state_dir "$DEPLOY_DIR"
acquire_deployment_lock "$DEPLOY_DIR"
require_stable_router_topology "$DEPLOY_DIR"
if [ "${DEPLOYMENT_ASSET_SHA:-}" != "$DEPLOY_SHA" ]; then
  prepare_exact_deployment_commit "$APP_DIR" "$DEPLOY_SHA" Main
  [ -x "${APP_DIR}/scripts/deploy-blue-green.sh" ] || { echo "Requested commit lacks Blue/Green deployment tooling." >&2; exit 1; }
  export DEPLOYMENT_ASSET_SHA="$DEPLOY_SHA"
  exec "${APP_DIR}/scripts/deploy-blue-green.sh" "$DEPLOY_SHA"
fi
verify_exact_deployment_commit "$APP_DIR" "$DEPLOY_SHA" Main
if docker info >/dev/null 2>&1; then DOCKER=(docker); elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker); else echo "Cannot access Docker." >&2; exit 1; fi
"${DOCKER[@]}" compose version >/dev/null
ROUTER_COMPOSE=("${DOCKER[@]}" compose -p zero-downtime-router -f "$ROUTER_FILE")
verify_project_revision() {
  local project="$1" file="$2" service="$3" expected_sha="$4" image_id revision
  image_id="$("${DOCKER[@]}" compose -p "$project" -f "$file" images -q "$service" | head -n 1)"
  [ -n "$image_id" ] || { echo "No image found for ${project}/${service}." >&2; return 1; }
  revision="$("${DOCKER[@]}" image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id")"
  [ "${revision,,}" = "$expected_sha" ] || { echo "Revision mismatch for ${project}/${service}." >&2; return 1; }
}
if [ -n "${APP_URL:-}" ]; then VERIFY_APP_URL="${APP_URL%/}"; elif [ -n "${EC2_HOST:-}" ]; then VERIFY_APP_URL="http://${EC2_HOST}"; else echo "APP_URL or EC2_HOST is required." >&2; exit 1; fi
snapshot_state() {
  local f n; STATE_SNAPSHOT="$(mktemp -d "${DEPLOY_DIR}/state-snapshot.XXXXXX")"
  for f in "$ACTIVE_FILE" "$CURRENT_FILE" "$PREVIOUS_FILE" "${DEPLOY_DIR}/blue.sha" "${DEPLOY_DIR}/green.sha"; do
    n="$(basename "$f")"; if [ -f "$f" ]; then cp -p -- "$f" "${STATE_SNAPSHOT}/${n}"; else : > "${STATE_SNAPSHOT}/${n}.absent"; fi
  done
}
restore_state_snapshot() {
  local n t; [ -n "$STATE_SNAPSHOT" ] && [ -d "$STATE_SNAPSHOT" ] || return 0
  for n in active-color current.sha previous.sha blue.sha green.sha; do
    t="${DEPLOY_DIR}/${n}"; if [ -f "${STATE_SNAPSHOT}/${n}" ]; then atomic_write_deployment_state "$t" "$(<"${STATE_SNAPSHOT}/${n}")" || true; else rm -f -- "$t"; fi
  done
}
candidate_diagnostics() {
  [ "${#CANDIDATE_COMPOSE[@]}" -gt 0 ] || return 0
  echo "Candidate diagnostics for ${CANDIDATE_COLOR}:" >&2
  "${CANDIDATE_COMPOSE[@]}" ps >&2 || true
  "${CANDIDATE_COMPOSE[@]}" logs --tail=100 frontend backend >&2 || true
}
handle_failure() {
  local status="${1:-1}"; trap - ERR; [ "$status" -ne 0 ] || status=1
  candidate_diagnostics
  write_deployment_sha_file "${DEPLOY_DIR}/failed-candidate.sha" "$DEPLOY_SHA" "Failed candidate SHA" || true
  if [ "$ROUTER_SWITCH_APPLIED" = true ]; then
    echo "Activation failed; restoring the previous router target." >&2
    restore_previous_router || echo "MANUAL RECOVERY REQUIRED: router restoration failed." >&2
    ./scripts/verify-deployment.sh "$VERIFY_APP_URL" || echo "MANUAL RECOVERY REQUIRED: restored public target did not verify." >&2
  fi
  [ "$STATE_COMMIT_STARTED" = false ] || restore_state_snapshot
  clear_candidate_deployment_color "$DEPLOY_DIR" || true
  router_switch_cleanup
  exit "$status"
}
trap 'handle_failure $?' ERR
if [ -e "$CANDIDATE_FILE" ]; then read_candidate_deployment_color "$DEPLOY_DIR" >/dev/null; echo "Clearing validated stale candidate state."; clear_candidate_deployment_color "$DEPLOY_DIR"; fi
if [ ! -e "$ACTIVE_FILE" ]; then
  FIRST_ACTIVATION=true; CANDIDATE_COLOR=blue
  OLD_CURRENT_SHA="$(read_deployment_sha_file "$CURRENT_FILE" "Legacy deployment SHA")"
  expected="$("$ROUTER_RENDERER" legacy)"; [ "$(<"$ROUTER_CONFIG")" = "$expected" ] || { echo "First activation requires legacy router aliases." >&2; exit 1; }
  legacy_running="$("${DOCKER[@]}" compose -p zero-downtime-app -f "$LEGACY_FILE" ps --services --status running | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$legacy_running" = "backend frontend" ] || { echo "First activation requires live zero-downtime-app." >&2; exit 1; }
  verify_project_revision zero-downtime-app "$LEGACY_FILE" frontend "$OLD_CURRENT_SHA"
  verify_project_revision zero-downtime-app "$LEGACY_FILE" backend "$OLD_CURRENT_SHA"
  ./scripts/verify-deployment.sh "$VERIFY_APP_URL"
  echo "Current active color: legacy"
else
  ACTIVE_COLOR="$(read_active_deployment_color "$DEPLOY_DIR")"; CANDIDATE_COLOR="$(opposite_deployment_color "$ACTIVE_COLOR")"
  OLD_CURRENT_SHA="$(read_deployment_sha_file "$CURRENT_FILE" "Current deployment SHA")"; active_sha="$(read_color_deployment_sha "$DEPLOY_DIR" "$ACTIVE_COLOR")"
  [ "$OLD_CURRENT_SHA" = "$active_sha" ] || { echo "Active color SHA and current.sha disagree." >&2; exit 1; }
  expected="$("$ROUTER_RENDERER" "$ACTIVE_COLOR")"; [ "$(<"$ROUTER_CONFIG")" = "$expected" ] || { echo "Router configuration and active-color disagree." >&2; exit 1; }
  ./scripts/verify-color-candidate.sh "$ACTIVE_COLOR" "$OLD_CURRENT_SHA"
  echo "Current active color: ${ACTIVE_COLOR}"
fi
[ "$CANDIDATE_COLOR" != "$ACTIVE_COLOR" ] || { echo "Candidate color cannot equal active color." >&2; exit 1; }
PROJECT_NAME="$(deployment_project_for_color "$CANDIDATE_COLOR")"; [ "$PROJECT_NAME" = "zero-downtime-${CANDIDATE_COLOR}" ] || { echo "Candidate project mismatch." >&2; exit 1; }
write_candidate_deployment_color "$DEPLOY_DIR" "$CANDIDATE_COLOR"
echo "Selected candidate color: ${CANDIDATE_COLOR}"; echo "Candidate SHA: ${DEPLOY_SHA}"
export DEPLOY_COLOR="$CANDIDATE_COLOR" IMAGE_TAG="$DEPLOY_SHA" DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
CANDIDATE_COMPOSE=("${DOCKER[@]}" compose -p "$PROJECT_NAME" -f "$APP_FILE")
"${CANDIDATE_COMPOSE[@]}" config --quiet
if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then printf '%s' "$GHCR_TOKEN" | "${DOCKER[@]}" login ghcr.io -u "$GHCR_USERNAME" --password-stdin; fi
"${CANDIDATE_COMPOSE[@]}" pull
"${CANDIDATE_COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 60
"${CANDIDATE_COMPOSE[@]}" ps
echo "Private verification: ${CANDIDATE_COLOR}"
./scripts/verify-color-candidate.sh "$CANDIDATE_COLOR" "$DEPLOY_SHA"
render_and_validate_router_candidate "$CANDIDATE_COLOR"
apply_router_candidate
echo "Public verification: ${CANDIDATE_COLOR}"
./scripts/verify-deployment.sh "$VERIFY_APP_URL"
"${ROUTER_COMPOSE[@]}" exec -T nginx wget -q -O /dev/null http://127.0.0.1/router-health
./scripts/verify-color-candidate.sh "$CANDIDATE_COLOR" "$DEPLOY_SHA"
snapshot_state; STATE_COMMIT_STARTED=true
commit_blue_green_state "$DEPLOY_DIR" "$OLD_CURRENT_SHA" "$CANDIDATE_COLOR" "$DEPLOY_SHA"
STATE_COMMIT_STARTED=false; trap - ERR
router_switch_cleanup; rm -rf -- "$STATE_SNAPSHOT"
echo "Final active color: ${CANDIDATE_COLOR}"
[ "$FIRST_ACTIVATION" = false ] || echo "Legacy zero-downtime-app remains running for compatibility rollback."
[ -z "$ACTIVE_COLOR" ] || echo "Previous color ${ACTIVE_COLOR} remains running for rollback."
