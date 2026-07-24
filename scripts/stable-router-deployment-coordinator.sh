#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <app-dir> <deployment-sha> <public-ec2-host>" >&2
  exit 1
fi

app_dir="$1"
deploy_sha="$2"
ec2_host="$3"
app_url="http://${ec2_host}"
topology_file="$app_dir/.deploy/topology"
legacy_file=compose/docker-compose.prod.yml
app_file=compose/docker-compose.app-legacy.yml
router_file=compose/docker-compose.router.yml

cd "$app_dir"
source scripts/lib/deployment-common.sh
validate_deployment_sha "$deploy_sha" "Workflow deployment SHA"
verify_exact_deployment_commit "$app_dir" "$deploy_sha" Main

verify_project_services() {
  local project="$1" file="$2" expected="$3" actual
  actual=$(docker compose -p "$project" -f "$file" ps --services --status running | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$actual" = "$expected" ] || {
    echo "Unexpected running services for ${project}: ${actual:-none}; expected ${expected}." >&2
    return 1
  }
  docker compose -p "$project" -f "$file" ps
}

verify_revision() {
  local project="$1" file="$2" service="$3" expected_sha="$4" image_id revision
  image_id=$(docker compose -p "$project" -f "$file" images -q "$service" | head -n 1)
  [ -n "$image_id" ] || { echo "No image found for ${project}/${service}." >&2; return 1; }
  revision=$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_id")
  [ "${revision,,}" = "${expected_sha,,}" ] || {
    echo "Revision mismatch for ${project}/${service}: expected ${expected_sha}, found ${revision:-missing}." >&2
    return 1
  }
}

verify_stable_router() {
  local expected_sha
  expected_sha=$(read_deployment_sha_file "$app_dir/.deploy/current.sha" "Current deployment SHA")
  export IMAGE_TAG="$expected_sha"
  export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
  verify_project_services zero-downtime-app "$app_file" "backend frontend"
  verify_project_services zero-downtime-router "$router_file" "nginx notifier"
  docker network inspect zero-downtime-router >/dev/null
  curl -fsS "${app_url}/router-health" >/dev/null
  curl -fsS "${app_url}/" >/dev/null
  curl -fsS "${app_url}/api/health" >/dev/null
  curl -fsS http://127.0.0.1:9001/health >/dev/null
  test "$(tr -d '[:space:]' < "$topology_file")" = stable-router
  if [ -n "$(docker ps -q --filter label=com.docker.compose.project=zero-downtime)" ]; then
    echo "Legacy zero-downtime project still has running containers." >&2
    return 1
  fi
  verify_revision zero-downtime-app "$app_file" frontend "$expected_sha"
  verify_revision zero-downtime-app "$app_file" backend "$expected_sha"
  verify_revision zero-downtime-router "$router_file" notifier "$expected_sha"
}

if [ -e "$topology_file" ]; then
  topology="$(tr -d '[:space:]' < "$topology_file")"
else
  topology=absent
fi

case "$topology" in
  absent)
    APP_URL="$app_url" EC2_HOST="$ec2_host" EC2_APP_DIR="$app_dir" \
      GHCR_USERNAME="${GHCR_USERNAME:-}" GHCR_TOKEN="${GHCR_TOKEN:-}" \
      DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
      ./scripts/deploy.sh "$deploy_sha"
    export IMAGE_TAG="$deploy_sha"
    verify_project_services zero-downtime "$legacy_file" "backend frontend nginx notifier"
    ./scripts/verify-deployment.sh "$app_url"
    curl -fsS http://127.0.0.1:9001/health >/dev/null
    test "$(tr -d '[:space:]' < .deploy/current.sha)" = "${deploy_sha,,}"
    APP_URL="$app_url" EC2_HOST="$ec2_host" EC2_APP_DIR="$app_dir" \
      GHCR_USERNAME="${GHCR_USERNAME:-}" GHCR_TOKEN="${GHCR_TOKEN:-}" \
      DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" \
      bash scripts/migrate-to-stable-router.sh "$deploy_sha"
    ;;
  stable-router)
    echo "The one-time stable-router migration has already completed; verifying without mutation."
    ;;
  *)
    echo "Unknown topology marker value: ${topology:-empty}" >&2
    exit 1
    ;;
esac

verify_stable_router
echo "Stable-router topology verification completed successfully."
