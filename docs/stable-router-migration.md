# Stable Router Migration Runbook

This is a separate, one-time operator action. The normal production deployment
and rollback paths still use the legacy single Compose project. CI validates
the migration tooling but never runs it.

## Preconditions

- Work on the production host in the clean deployment checkout.
- Docker, Docker Compose, `curl`, and `flock` must be available.
- The legacy `zero-downtime` Compose project must be healthy and own ports 80
  and 9001; no stable-router app or router project may already be running.
- Use the full 40-character SHA already recorded in `.deploy/current.sha`.
- Exact-SHA frontend, backend, notifier, and Nginx images must be available.
- At least 1 GiB of disk space must be free.
- `APP_URL`, or `EC2_HOST` from which it can be derived, must identify the
  public service.

## Run

```bash
cd /opt/zero-downtime
bash scripts/migrate-to-stable-router.sh <full-commit-sha>
```

The command takes the same deployment lock as deploy and rollback. It prepares
the external `zero-downtime-router` network, pulls exact-SHA images, starts and
verifies the app project internally, and only then stops the legacy project.
It starts the stable router and checks `/router-health`, the notifier loopback
endpoint, the public application, and OCI revision labels before atomically
writing `.deploy/topology` as `stable-router`.

## Failure and recovery behavior

Before legacy shutdown, a failure removes prepared resources and leaves the
legacy service online. During or after shutdown, a failure stops the new router
and app, then restores and verifies the legacy project. Existing
operator-created networks are preserved. `current.sha`, `previous.sha`, and
`failed.sha` are not rewritten by this same-SHA topology migration.

The script reports the failed phase, Compose state and logs, port ownership,
the measured interruption/verification window, and explicit manual recovery
commands if automatic restoration cannot be confirmed. The principal public
service interruption starts when the legacy project is stopped and ends after
the stable router or restored legacy service passes verification.

## Safe local and CI checks

The transaction suite mocks Docker and never performs a migration:

```bash
bash -n scripts/migrate-to-stable-router.sh
bash -n scripts/lib/*.sh
bash -n scripts/tests/*.sh
bash scripts/tests/test-stable-router-migration.sh
git diff --check HEAD^ HEAD
```

On a Docker-capable machine, also render the topology and validate Nginx without
starting production services:

```bash
bash scripts/tests/test-router-topology.sh
docker compose -p zero-downtime-app -f compose/docker-compose.app-legacy.yml config --quiet
DEPLOY_COLOR=blue IMAGE_TAG=0000000000000000000000000000000000000000 \
  docker compose -p zero-downtime-blue -f compose/docker-compose.app.yml config --quiet
DEPLOY_COLOR=green IMAGE_TAG=0000000000000000000000000000000000000000 \
  docker compose -p zero-downtime-green -f compose/docker-compose.app.yml config --quiet
docker compose -f compose/docker-compose.router.yml config --quiet
bash scripts/tests/test-router-rendering.sh
```
