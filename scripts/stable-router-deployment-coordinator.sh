#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] || { echo "Usage: $0 <app-dir> <deployment-sha> <public-ec2-host>" >&2; exit 1; }
app_dir="$1"; deploy_sha="$2"; ec2_host="$3"; app_url="http://${ec2_host}"
topology_file="$app_dir/.deploy/topology"
cd "$app_dir"
source scripts/lib/deployment-common.sh
validate_deployment_sha "$deploy_sha" "Workflow deployment SHA"
verify_exact_deployment_commit "$app_dir" "$deploy_sha" Main

verify_router_control_plane() {
  local running
  running="$(docker compose -p zero-downtime-router -f compose/docker-compose.router.yml ps --services --status running | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$running" = "nginx notifier" ] || { echo "Stable router services are not healthy: ${running:-none}." >&2; return 1; }
  docker network inspect zero-downtime-router >/dev/null
  curl -fsS "${app_url}/router-health" >/dev/null
  curl -fsS http://127.0.0.1:9001/health >/dev/null
}

verify_stable_router() {
  local current_sha active_color expected
  require_stable_router_topology "$app_dir/.deploy"
  current_sha="$(read_deployment_sha_file "$app_dir/.deploy/current.sha" "Current deployment SHA")"
  if [ -n "$(docker ps -q --filter label=com.docker.compose.project=zero-downtime)" ]; then
    echo "Pre-migration combined zero-downtime project is unexpectedly running." >&2
    return 1
  fi
  verify_router_control_plane
  ./scripts/verify-deployment.sh "$app_url"
  if [ -e "$app_dir/.deploy/active-color" ]; then
    active_color="$(read_active_deployment_color "$app_dir/.deploy")"
    expected="$(read_color_deployment_sha "$app_dir/.deploy" "$active_color")"
    [ "$current_sha" = "$expected" ] || { echo "Active color and current SHA disagree." >&2; return 1; }
    ./scripts/verify-color-candidate.sh "$active_color" "$current_sha"
    echo "Final active color: ${active_color}"
  else
    running="$(docker compose -p zero-downtime-app -f compose/docker-compose.app-legacy.yml ps --services --status running | sort | tr '\n' ' ' | sed 's/ $//')"
    [ "$running" = "backend frontend" ] || { echo "Legacy compatibility application is unavailable." >&2; return 1; }
    echo "Final active color: legacy"
  fi
}

if [ -e "$topology_file" ]; then topology="$(tr -d '[:space:]' < "$topology_file")"; else topology=absent; fi
echo "Topology: ${topology}"
case "$topology" in
  absent)
    APP_URL="$app_url" EC2_HOST="$ec2_host" EC2_APP_DIR="$app_dir" \
      GHCR_USERNAME="${GHCR_USERNAME:-}" GHCR_TOKEN="${GHCR_TOKEN:-}" DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
      ./scripts/deploy.sh "$deploy_sha"
    APP_URL="$app_url" EC2_HOST="$ec2_host" EC2_APP_DIR="$app_dir" \
      GHCR_USERNAME="${GHCR_USERNAME:-}" GHCR_TOKEN="${GHCR_TOKEN:-}" DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
      bash scripts/migrate-to-stable-router.sh "$deploy_sha"
    ;;
  stable-router)
    echo "Stable-router topology already active; migration is skipped."
    ;;
  *) echo "Unknown topology marker value: ${topology:-empty}" >&2; exit 1 ;;
esac

APP_URL="$app_url" EC2_HOST="$ec2_host" EC2_APP_DIR="$app_dir" DEPLOYMENT_ASSET_SHA="$deploy_sha" \
  GHCR_USERNAME="${GHCR_USERNAME:-}" GHCR_TOKEN="${GHCR_TOKEN:-}" DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
  ./scripts/deploy-blue-green.sh "$deploy_sha"
verify_stable_router
echo "Stable-router Blue/Green deployment completed successfully."
