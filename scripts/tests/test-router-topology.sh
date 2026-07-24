#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
ROUTER_COMPOSE="${ROOT_DIR}/compose/docker-compose.router.yml"
LEGACY_APP_COMPOSE="${ROOT_DIR}/compose/docker-compose.app-legacy.yml"
COLOR_APP_COMPOSE="${ROOT_DIR}/compose/docker-compose.app.yml"
PROD_COMPOSE="${ROOT_DIR}/compose/docker-compose.prod.yml"
ROUTER_CONFIG="${ROOT_DIR}/nginx/router.conf"
DUMMY_SHA="0000000000000000000000000000000000000000"
TEST_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

for required_file in "$ROUTER_COMPOSE" "$LEGACY_APP_COMPOSE" "$COLOR_APP_COMPOSE" "$PROD_COMPOSE" "$ROUTER_CONFIG"; do
  if [ ! -f "$required_file" ]; then
    echo "Topology validation failed: missing ${required_file}" >&2
    exit 1
  fi
done

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Topology validation not run: Docker Compose is unavailable." >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Topology validation not run: Node.js is unavailable for structured Compose checks." >&2
  exit 2
fi

export IMAGE_TAG="$DUMMY_SHA"
export DISCORD_WEBHOOK_URL=""

docker compose -p zero-downtime -f "$PROD_COMPOSE" config --format json > "${TEST_DIR}/prod.json"
docker compose -p zero-downtime-app -f "$LEGACY_APP_COMPOSE" config --format json > "${TEST_DIR}/app.json"
DEPLOY_COLOR=blue docker compose -p zero-downtime-blue -f "$COLOR_APP_COMPOSE" config --format json > "${TEST_DIR}/blue.json"
DEPLOY_COLOR=green docker compose -p zero-downtime-green -f "$COLOR_APP_COMPOSE" config --format json > "${TEST_DIR}/green.json"
docker compose -p zero-downtime-router -f "$ROUTER_COMPOSE" config --format json > "${TEST_DIR}/router.json"

export PROD_JSON="${TEST_DIR}/prod.json"
export APP_JSON="${TEST_DIR}/app.json"
export BLUE_JSON="${TEST_DIR}/blue.json"
export GREEN_JSON="${TEST_DIR}/green.json"
export ROUTER_JSON="${TEST_DIR}/router.json"
export ROUTER_CONFIG
export DEPLOY_SCRIPT="${ROOT_DIR}/scripts/deploy.sh"
export ROLLBACK_SCRIPT="${ROOT_DIR}/scripts/rollback.sh"
export BLUE_GREEN_DEPLOY_SCRIPT="${ROOT_DIR}/scripts/deploy-blue-green.sh"
export BLUE_GREEN_ROLLBACK_SCRIPT="${ROOT_DIR}/scripts/rollback-blue-green.sh"

node <<'NODE'
const fs = require('node:fs')

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function serviceNames(config) {
  return Object.keys(config.services || {}).sort()
}

function ports(service) {
  return service.ports || []
}

function hasPort(service, published, target, hostIp) {
  return ports(service).some((port) =>
    String(port.published) === String(published) &&
    String(port.target) === String(target) &&
    (hostIp === undefined || port.host_ip === hostIp)
  )
}

function networkAliases(service, network) {
  return service.networks?.[network]?.aliases || []
}

function hasNetwork(service, network) {
  return Object.hasOwn(service.networks || {}, network)
}

const prod = readJson(process.env.PROD_JSON)
const app = readJson(process.env.APP_JSON)
const blue = readJson(process.env.BLUE_JSON)
const green = readJson(process.env.GREEN_JSON)
const router = readJson(process.env.ROUTER_JSON)
const routerConfig = fs.readFileSync(process.env.ROUTER_CONFIG, 'utf8')
const deployScript = fs.readFileSync(process.env.DEPLOY_SCRIPT, 'utf8')
const rollbackScript = fs.readFileSync(process.env.ROLLBACK_SCRIPT, 'utf8')

assert(
  JSON.stringify(serviceNames(router)) === JSON.stringify(['nginx', 'notifier']),
  'router Compose must contain only nginx and notifier'
)
assert(
  JSON.stringify(serviceNames(app)) === JSON.stringify(['backend', 'frontend']),
  'application Compose must contain only frontend and backend'
)
for (const [color, config] of [['blue', blue], ['green', green]]) {
  assert(
    JSON.stringify(serviceNames(config)) === JSON.stringify(['backend', 'frontend']),
    `${color} application Compose must contain only frontend and backend`
  )
  assert(ports(config.services.frontend).length === 0, `${color} frontend must not publish a host port`)
  assert(ports(config.services.backend).length === 0, `${color} backend must not publish a host port`)
  assert(
    networkAliases(config.services.frontend, 'router').includes(`${color}-frontend`),
    `${color} frontend alias is missing`
  )
  assert(
    networkAliases(config.services.backend, 'router').includes(`${color}-backend`),
    `${color} backend alias is missing`
  )
  assert(
    !networkAliases(config.services.frontend, 'router').includes('app-frontend') &&
      !networkAliases(config.services.backend, 'router').includes('app-backend'),
    `${color} must not claim the live application aliases`
  )
}
assert(
  JSON.stringify(serviceNames(prod)) === JSON.stringify(['backend', 'frontend', 'nginx', 'notifier']),
  'legacy production Compose service set changed unexpectedly'
)

assert(hasPort(router.services.nginx, 80, 80), 'router Nginx must publish host port 80')
assert(
  hasPort(router.services.notifier, 9001, 4000, '127.0.0.1'),
  'notifier must retain 127.0.0.1:9001:4000'
)
assert(ports(app.services.frontend).length === 0, 'frontend must not publish a host port')
assert(ports(app.services.backend).length === 0, 'backend must not publish a host port')

const publishedPort80 = Object.entries({...router.services, ...app.services})
  .flatMap(([name, service]) => ports(service).map((port) => ({name, port})))
  .filter(({port}) => String(port.published) === '80')
assert(
  publishedPort80.length === 1 && publishedPort80[0].name === 'nginx',
  'Nginx must be the only prepared-topology service publishing host port 80'
)

for (const config of [router, app]) {
  assert(config.networks?.router?.external === true, 'shared router network must be external')
  assert(
    config.networks.router.name === 'zero-downtime-router',
    'both projects must use the zero-downtime-router network'
  )
}

assert(hasNetwork(router.services.nginx, 'router'), 'router Nginx must join the shared network')
assert(hasNetwork(app.services.frontend, 'default'), 'frontend must retain a project-local network')
assert(hasNetwork(app.services.backend, 'default'), 'backend must retain a project-local network')
assert(
  networkAliases(app.services.frontend, 'router').includes('app-frontend'),
  'frontend shared-network alias is missing'
)
assert(
  networkAliases(app.services.backend, 'router').includes('app-backend'),
  'backend shared-network alias is missing'
)

assert(app.services.backend.healthcheck, 'backend health check must be preserved')
assert(router.services.notifier.healthcheck, 'notifier health check must be preserved')
assert(router.services.nginx.healthcheck, 'router Nginx health check is required')
assert(
  JSON.stringify(router.services.nginx.healthcheck.test).includes('/router-health'),
  'router health check must use /router-health'
)
assert(!router.services.nginx.depends_on, 'stable router must not depend on application services')

assert(routerConfig.includes('resolver 127.0.0.11'), 'router must use Docker DNS')
assert(routerConfig.includes('valid=10s'), 'router DNS cache lifetime must be explicit')
assert(routerConfig.includes('app-frontend'), 'router must use app-frontend')
assert(routerConfig.includes('app-backend'), 'router must use app-backend')
assert(routerConfig.includes('location = /router-health'), 'router-owned health endpoint is missing')
assert(
  !/proxy_pass\s+http:\/\/(?:frontend|backend)(?=[:;/\s])/.test(routerConfig),
  'router must not use generic frontend/backend upstream hostnames'
)

for (const script of [deployScript, rollbackScript]) {
  assert(script.includes('compose/docker-compose.prod.yml'), 'legacy compatibility entrypoints must remain available')
}
const blueGreenDeploy = fs.readFileSync(process.env.BLUE_GREEN_DEPLOY_SCRIPT, 'utf8')
const blueGreenRollback = fs.readFileSync(process.env.BLUE_GREEN_ROLLBACK_SCRIPT, 'utf8')
assert(blueGreenDeploy.includes('compose/docker-compose.app.yml'), 'Blue/Green deploy must use color Compose')
assert(blueGreenDeploy.includes('compose/docker-compose.router.yml'), 'Blue/Green deploy must control stable router')
assert(blueGreenRollback.includes('compose/docker-compose.app.yml'), 'Blue/Green rollback must use retained color')

console.log('Router topology validation passed.')
NODE
