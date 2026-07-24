#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/deployment-common.sh"
source "${SCRIPT_DIR}/lib/router-switch.sh"
[ "$#" -eq 0 ] || { echo "Usage: $0" >&2; exit 1; }
APP_DIR="${EC2_APP_DIR:-/home/ubuntu/Zero-Downtime-Deployment-System}"
DEPLOY_DIR="${APP_DIR}/.deploy"; APP_FILE=compose/docker-compose.app.yml; ROUTER_FILE=compose/docker-compose.router.yml
ROUTER_CONFIG="$(runtime_router_config_path "$DEPLOY_DIR")"; ROUTER_RENDERER="${APP_DIR}/scripts/render-router-config.sh"
CURRENT_FILE="${DEPLOY_DIR}/current.sha"; PREVIOUS_FILE="${DEPLOY_DIR}/previous.sha"
DOCKER=(); ROUTER_COMPOSE=(); TARGET_COMPOSE=(); STATE_DIR=""; STATE_WRITING=false
cd "$APP_DIR"; ensure_deployment_state_dir "$DEPLOY_DIR"; acquire_deployment_lock "$DEPLOY_DIR"; require_stable_router_topology "$DEPLOY_DIR"
ROUTER_CONFIG="$(ensure_runtime_router_config "$DEPLOY_DIR" "$ROUTER_RENDERER")"
ACTIVE_COLOR="$(read_active_deployment_color "$DEPLOY_DIR")"; TARGET_COLOR="$(opposite_deployment_color "$ACTIVE_COLOR")"
CURRENT_SHA="$(read_deployment_sha_file "$CURRENT_FILE" "Current deployment SHA")"
ACTIVE_SHA="$(read_color_deployment_sha "$DEPLOY_DIR" "$ACTIVE_COLOR")"; [ "$CURRENT_SHA" = "$ACTIVE_SHA" ] || { echo "Active color state is inconsistent." >&2; exit 1; }
TARGET_SHA="$(read_color_deployment_sha "$DEPLOY_DIR" "$TARGET_COLOR")"
RECORDED_PREVIOUS_SHA="$(read_deployment_sha_file "$PREVIOUS_FILE" "Retained rollback SHA")"
[ "$RECORDED_PREVIOUS_SHA" = "$TARGET_SHA" ] || { echo "previous.sha does not identify the retained opposite color." >&2; exit 1; }
if [ -e "${DEPLOY_DIR}/candidate-color" ]; then read_candidate_deployment_color "$DEPLOY_DIR" >/dev/null; clear_candidate_deployment_color "$DEPLOY_DIR"; fi
if docker info >/dev/null 2>&1; then DOCKER=(docker); elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker); else echo "Cannot access Docker." >&2; exit 1; fi
ROUTER_COMPOSE=("${DOCKER[@]}" compose -p zero-downtime-router -f "$ROUTER_FILE")
TARGET_COMPOSE=("${DOCKER[@]}" compose -p "$(deployment_project_for_color "$TARGET_COLOR")" -f "$APP_FILE")
export DEPLOY_COLOR="$TARGET_COLOR" IMAGE_TAG="$TARGET_SHA"
"${TARGET_COMPOSE[@]}" config --quiet
running="$("${TARGET_COMPOSE[@]}" ps --services --status running | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$running" = "backend frontend" ] || { echo "Retained ${TARGET_COLOR} project is not fully running." >&2; exit 1; }
if [ -n "${APP_URL:-}" ]; then VERIFY_APP_URL="${APP_URL%/}"; elif [ -n "${EC2_HOST:-}" ]; then VERIFY_APP_URL="http://${EC2_HOST}"; else echo "APP_URL or EC2_HOST is required." >&2; exit 1; fi
snapshot() { STATE_DIR="$(mktemp -d "${DEPLOY_DIR}/rollback-state.XXXXXX")"; cp -p -- "${DEPLOY_DIR}/active-color" "$CURRENT_FILE" "$PREVIOUS_FILE" "$STATE_DIR/"; }
restore_state() { [ -d "$STATE_DIR" ] || return 0; atomic_write_deployment_state "${DEPLOY_DIR}/active-color" "$(<"${STATE_DIR}/active-color")" || true; atomic_write_deployment_state "$CURRENT_FILE" "$(<"${STATE_DIR}/current.sha")" || true; atomic_write_deployment_state "$PREVIOUS_FILE" "$(<"${STATE_DIR}/previous.sha")" || true; }
fail_rollback() {
  local status="${1:-1}"; trap - ERR
  if [ "$ROUTER_SWITCH_APPLIED" = true ]; then restore_previous_router || echo "MANUAL RECOVERY REQUIRED: router restoration failed." >&2; ./scripts/verify-deployment.sh "$VERIFY_APP_URL" || true; fi
  [ "$STATE_WRITING" = false ] || restore_state
  clear_candidate_deployment_color "$DEPLOY_DIR" || true; router_switch_cleanup; exit "$status"
}
trap 'fail_rollback $?' ERR
write_candidate_deployment_color "$DEPLOY_DIR" "$TARGET_COLOR"
echo "Rollback retained color: ${TARGET_COLOR}"; echo "Rollback SHA: ${TARGET_SHA}"
./scripts/verify-color-candidate.sh "$TARGET_COLOR" "$TARGET_SHA"
render_and_validate_router_candidate "$TARGET_COLOR"
apply_router_candidate
./scripts/verify-deployment.sh "$VERIFY_APP_URL"
"${ROUTER_COMPOSE[@]}" exec -T nginx wget -q -O /dev/null http://127.0.0.1/router-health
./scripts/verify-color-candidate.sh "$TARGET_COLOR" "$TARGET_SHA"
snapshot; STATE_WRITING=true
commit_blue_green_state "$DEPLOY_DIR" "$CURRENT_SHA" "$TARGET_COLOR" "$TARGET_SHA"
STATE_WRITING=false; trap - ERR
router_switch_cleanup; rm -rf -- "$STATE_DIR"
echo "Rollback succeeded. Final active color: ${TARGET_COLOR}. Retained ${ACTIVE_COLOR} remains running."
