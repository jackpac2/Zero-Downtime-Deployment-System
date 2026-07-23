# Zero Downtime Deployment System

## Project Structure

The application source code is shared between development and production:

- `frontend/` contains the frontend application and Dockerfile.
- `backend/` contains the backend application and Dockerfile.
- `nginx/` contains the Nginx reverse proxy configuration.
- `compose/docker-compose.dev.yml` is for local development and manual testing.
- `compose/docker-compose.prod.yml` is for production deployment on EC2.
- `compose/docker-compose.router.yml` prepares the stable Nginx and notifier project.
- `compose/docker-compose.app.yml` prepares the separately managed frontend and backend project.
- `scripts/ensure-ec2-repo.sh` bootstraps the repo into the ubuntu user's EC2 app directory if it is missing.
- `scripts/bootstrap-ec2-host.sh` idempotently installs Ubuntu prerequisites and configures non-sudo Docker access.
- `scripts/deploy.sh` is the EC2 deployment entrypoint.
- `scripts/migrate-to-stable-router.sh` performs the one-time legacy-to-stable-router migration.
- `.github/workflows/deploy.yml` is the GitHub Actions workflow.

There are no separate `dev/` and `prod/` app folders. Environment-specific behavior lives in Compose files and scripts, while the actual application code stays shared.

## Local Development

Use the development Compose file when running the stack locally:

```bash
docker compose -f compose/docker-compose.dev.yml up --build
```

The development Compose file may use `build` because local development should be able to rebuild the frontend and backend directly from source:

- Frontend build context: `../frontend`
- Backend build context: `../backend`
- Nginx config mount: `../nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro`

## Production Compose

Production uses:

```bash
compose/docker-compose.prod.yml
```

The production Compose file does not use `build`. It pulls prebuilt images from GitHub Container Registry:

```yaml
ghcr.io/jackpac2/zero-downtime-frontend:${IMAGE_TAG}
ghcr.io/jackpac2/zero-downtime-backend:${IMAGE_TAG}
```

Nginx remains the official `nginx:1.27-alpine` image and mounts:

```yaml
../nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
```

Production exposes:

```yaml
80:80
```

## Prepared Stable Router Topology

The repository contains a prepared split between the stable control plane and the application lifecycle:

```text
                 Port 80
                    |
       zero-downtime-router project
            Nginx + notifier
                    |
       zero-downtime-router network
          app-frontend / app-backend
                    |
         zero-downtime-app project
           frontend + backend
```

`compose/docker-compose.router.yml` contains only public Nginx and the deployment notifier. Nginx owns port `80`, mounts `nginx/router.conf` read-only, and provides `/router-health` without contacting either application service. The notifier retains `127.0.0.1:9001:4000`, its webhook environment variable, and its health check.

`compose/docker-compose.app.yml` contains only frontend and backend. Both remain on the application's project-local default network. They also join the external `zero-downtime-router` network with the unique aliases `app-frontend` and `app-backend`. Neither service publishes a host port.

The external network must be created once before either prepared project is started:

```bash
docker network create zero-downtime-router
```

Because the network is declared `external`, normal `docker compose down` operations for either project do not delete it.

The prepared router uses Docker's embedded DNS resolver at `127.0.0.11`. Its `proxy_pass` targets contain variables, so Nginx resolves `app-frontend` and `app-backend` while handling requests instead of resolving each name only when Nginx starts. Results are cached for at most 10 seconds. Recreating an application container can therefore give its alias a new IP without requiring a router restart. While an alias is temporarily unavailable, proxied application requests return an upstream error, but `/router-health` continues returning `200`; Nginx retries DNS resolution and recovers when the alias is available again.

Production deployment and rollback still use `compose/docker-compose.prod.yml`, the original `nginx/nginx.conf`, and the single `zero-downtime` Compose project. The split files are activated only by the one-time manually dispatched migration. Normal stable-router deployment, stable-router rollback, Blue/Green environments, active-color state, and traffic switching are not implemented.

Validate the prepared topology without starting production services:

```bash
export IMAGE_TAG=0000000000000000000000000000000000000000
export DISCORD_WEBHOOK_URL=""

docker compose -p zero-downtime -f compose/docker-compose.prod.yml config
docker compose -p zero-downtime-app -f compose/docker-compose.app.yml config
docker compose -p zero-downtime-router -f compose/docker-compose.router.yml config
bash scripts/tests/test-router-topology.sh
docker run --rm \
  --volume "$PWD/nginx/router.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:1.27-alpine nginx -t
```

## Why Production Pulls Images

GitHub Actions is the build environment. EC2 is the runtime environment.

EC2 should not build the frontend or backend. It should only pull and run the exact image versions created by CI/CD. This keeps deployments reproducible, avoids installing build tooling on the server, and prepares the project for predictable rollback behavior in Phase 7.

## Deployment Script

The production deployment entrypoint is:

```bash
./scripts/deploy.sh <git-sha>
```

The script runs on EC2 from:

```bash
/home/ubuntu/Zero-Downtime-Deployment-System
```

It performs these steps:

- Requires a full 40-character hexadecimal Git SHA.
- Creates and validates `.deploy/`, then acquires `.deploy/deployment.lock` with `flock`.
- Fetches `origin/Main`, verifies that the requested commit belongs to its history, and refuses a dirty deployment checkout.
- Checks out the requested commit in detached-HEAD mode and re-executes `deploy.sh` from that exact commit.
- Exports `IMAGE_TAG=<git-sha>`, so the deployment scripts, Compose file, frontend, backend, and notifier all use the same commit.
- Copies a valid `.deploy/current.sha` to `.deploy/previous.sha` only after preflight checks pass.
- Runs `docker compose -p zero-downtime -f compose/docker-compose.prod.yml pull`.
- Runs `docker compose -p zero-downtime -f compose/docker-compose.prod.yml up -d --remove-orphans --wait`.
- Verifies the public frontend and `/api/health`, with automatic rollback on deployment failure.
- Removes unused old images with `docker image prune -f`.
- Shows running containers with `docker ps`.
- Writes `.deploy/current.sha` only after verification succeeds.

This remains an in-place deployment. Blue/Green environments and traffic switching are not implemented.

## Deployment Safety Prerequisites

`scripts/lib/deployment-common.sh` contains the SHA, lock, and exact-commit checks shared by deployment and rollback.

- Deployment and rollback SHAs must match `^[0-9a-fA-F]{40}$`. Short, long, whitespace-containing, empty, and non-hexadecimal values are rejected before Docker or state mutation.
- Deployments and rollbacks share `.deploy/deployment.lock`. Lock acquisition is fail-fast: a second operation exits clearly instead of waiting or overlapping.
- The lock file may remain after a crash, but that does not keep the system locked. The kernel releases the `flock` automatically when the owning process exits.
- Automatic rollback inherits the deployment's open lock descriptor, so it remains inside the same protected operation and does not deadlock.
- The workflow copies a safety-aware launcher from its own commit into `.deploy/bootstrap/<sha>/`. The launcher acquires the lock before fetching and checking out the requested SHA, then re-executes the repository's `deploy.sh` at that SHA.
- Queued Actions runs deploy their own SHA in turn. A later run fetches and deliberately checks out its requested commit rather than silently using the newest `Main` checkout.
- Commits deployed through the new workflow must contain the safety helper. Older commits remain valid rollback targets because the safety-aware rollback controller validates and checks out the target before running its exact rollback script under the inherited lock.

Manual deployment still uses:

```bash
./scripts/deploy.sh <full-40-character-git-sha>
```


Manual rollback still uses the validated SHA stored in `.deploy/previous.sha`:

```bash
./scripts/rollback.sh
```

## Ignored Deployment State

`.deploy/` is ignored by Git because it is server-side deployment state, not source code.

It may contain:

- `current.sha`
- `previous.sha`
- `failed.sha`
- `rolled-back-from.sha`
- `deployment.lock`

These files should stay on EC2 and should not be committed to GitHub.

## Production CI/CD Transition Flow

During stable-router activation, a push or merge to `Main`:

1. Validates the application, scripts, Compose files, Nginx configuration, migration transaction, and bootstrap safety tests.
2. Builds and publishes frontend, backend, and notifier images tagged with the full SHA, short SHA, and `latest`.
3. Prints that EC2 deployment is temporarily manual.
4. Does not SSH to EC2, deploy the legacy project, or run migration.

This temporary guard is required because `deploy.sh` and `rollback.sh` still operate only on the legacy `zero-downtime` project. The old automatic step could otherwise recreate Nginx on port 80 and the notifier on port 9001 after migration. Normal stable-router deployment and rollback are the next phase; automatic EC2 mutation must remain paused until that work is complete.
## Production CI/CD Flow

The production flow is:

1. Developer pushes to `Main`.
2. GitHub Actions validates the safety helpers and builds frontend, backend, and notifier Docker images.
3. GitHub Actions tags images with the full Git SHA, short Git SHA, and `latest`.
4. GitHub Actions pushes images to GHCR.
5. GitHub Actions connects to EC2 over SSH.
6. GitHub Actions copies and runs the exact-commit deployment launcher with `<git-sha>`.
7. EC2 validates and checks out that commit under the shared lock.
8. EC2 pulls, starts, verifies, and records the exact full-SHA image versions.

## Required GitHub Secrets

Required repository secrets:

| Secret | Expected value |
| --- | --- |
| `EC2_HOST` | Your EC2 public DNS name or public IP address |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Private SSH key that can connect to the EC2 instance |

`EC2_APP_DIR` is optional. If empty or unset, every bootstrap step uses exactly `/home/ubuntu/Zero-Downtime-Deployment-System`.

Optional secrets for private GHCR packages:

| Secret | Purpose |
| --- | --- |
| `EC2_APP_DIR` | Custom absolute checkout path; defaults to `/home/ubuntu/Zero-Downtime-Deployment-System` |
| `GHCR_USERNAME` | GitHub username used by EC2 for GHCR login |
| `GHCR_TOKEN` | GitHub Personal Access Token with package read access |
| `DISCORD_WEBHOOK_URL` | Webhook used by the notifier; may be empty |

If the GHCR packages are public, EC2 does not need GHCR login. If they are private, store a GitHub Personal Access Token with package read access as `GHCR_TOKEN`.

## One-Time EC2 Bootstrap and Stable-Router Migration

The one-time path is manual because it changes production topology while the normal deploy and rollback scripts are still legacy-only. In GitHub Actions, open **Build and Deploy**, choose **Run workflow** for the intended `Main` commit, enable `bootstrap_stable_router`, and start the run. A dispatch with the input disabled only validates, builds, and publishes images.

The EC2 security group must allow SSH port 22 from the permitted source and public HTTP port 80. Port 9001 must not be public; the notifier remains bound to `127.0.0.1` and is checked over SSH.

The bootstrap helper installs missing Git, curl, CA certificates, GnuPG, `util-linux` (`flock`), Docker Engine from Docker's signed official Ubuntu apt repository, and Docker Compose v2. It does not upgrade unrelated packages or reboot. It enables Docker and adds the deployment user to the `docker` group if needed. That SSH session ends, and a fresh connection must pass `docker info` and `docker compose version` without `sudo` before repository or production mutation.

The workflow prints the resolved application directory once, creates its parent for the deployment user, runs `ensure-ec2-repo.sh`, and uses `deployment-common.sh` to prepare and verify the exact workflow SHA from `origin/Main` under `flock`.

It reads `.deploy/topology` as plain text:

- No marker means fresh or legacy. The workflow calls `deploy.sh`, verifies the combined `zero-downtime` project and `.deploy/current.sha`, then calls `migrate-to-stable-router.sh`.
- Exactly `stable-router` means migration already completed. It skips legacy deployment and migration, then verifies the application and router projects, shared network, health endpoints, exact legacy-project absence, and image revision labels.
- Any other value fails before production mutation.

Legacy is deployed first because migration preflight requires a healthy combined stack whose `current.sha` matches the requested image SHA. `deploy.sh` continues to own legacy Compose, verification, and rollback. The migration script owns network creation, application preparation, legacy shutdown, router startup, transaction cleanup, legacy restoration, and the atomic topology marker.

If migration fails before cutover, it cleans prepared resources. If it fails after legacy shutdown, it stops new resources and attempts to restore and verify legacy. The workflow remains failed even if restoration succeeds. A final-verification failure produces safe status diagnostics without broad workflow cleanup.

Repeated manual runs are idempotent: a healthy `stable-router` marker selects verification-only behavior. The marker prevents manual remigration, while the push guard prevents automatic legacy recreation. Do not manually run legacy `deploy.sh` or `rollback.sh` after migration; stable-router-aware versions are the next phase.

Final EC2 checks:

```bash
cd /home/ubuntu/Zero-Downtime-Deployment-System
export IMAGE_TAG="$(tr -d '[:space:]' < .deploy/current.sha)"
docker compose -p zero-downtime-app -f compose/docker-compose.app.yml ps
docker compose -p zero-downtime-router -f compose/docker-compose.router.yml ps
docker network inspect zero-downtime-router
curl -fsS http://localhost/router-health
curl -fsS http://localhost/
curl -fsS http://localhost/api/health
curl -fsS http://127.0.0.1:9001/health
test "$(tr -d '[:space:]' < .deploy/topology)" = stable-router
test -z "$(docker ps -q --filter label=com.docker.compose.project=zero-downtime)"
```

Operator runbook:

1. Merge to `Main`.
2. Confirm validation, exact-SHA builds, and GHCR publication succeed, and confirm the push summary says EC2 mutation was skipped.
3. Verify the required secrets, then manually dispatch **Build and Deploy** with `bootstrap_stable_router=true` for that commit.
4. Monitor prerequisite installation, the fresh-session Docker check, exact-commit preparation, legacy deployment, migration, and final verification.
5. Confirm the summary reports `stable-router` and all health checks passed.

This is not true Blue/Green deployment. There are no blue/green environments, active-color state, or traffic-switching controls.

## Required EC2 Setup

The manual workflow prepares a fresh Ubuntu host, but the instance must already have:

- An SSH deployment user, normally `ubuntu`, with passwordless sudo for package, service, and group administration.
- SSH access configured for `EC2_SSH_KEY`. The workflow accepts a new host key on first contact and rejects a changed key for the remainder of the run.
- Ports 22 and 80 allowed as described above.
- Ubuntu user: `ubuntu`
- Repository cloned at `/home/ubuntu/Zero-Downtime-Deployment-System`
- Docker installed
- Docker Compose v2 installed and available as `docker compose`
- Linux `flock` installed (normally provided by the `util-linux` package)
- Port `80` open in the EC2 security group
- SSH access configured for the private key stored in `EC2_SSH_KEY`

Useful checks on EC2:

```bash
docker --version
docker compose version
cd /home/ubuntu/Zero-Downtime-Deployment-System
git branch --show-current
```

## Making GHCR Packages Public

GitHub Actions can publish GHCR packages using `${{ github.actor }}` and `${{ secrets.GITHUB_TOKEN }}` with `packages: write`, but package visibility may need to be changed manually after the first package is created.

Manual steps:

1. Go to the GitHub repository.
2. Open the Packages section.
3. Select the container package.
4. Open Package settings.
5. Change visibility to Public.

Repeat this for:

- `zero-downtime-frontend`
- `zero-downtime-backend`

## CI/CD Validation Added in Phase 6

The deployment workflow validates the app before publishing images:

- Frontend: `npm ci`, `npm run lint --if-present`, `npm test --if-present`, and `npm run build`.
- Backend: `npm ci`, `npm run lint --if-present`, `npm test --if-present`, and `npm run check --if-present`.
- Production Compose: `IMAGE_TAG=<git-sha> docker compose -p zero-downtime -f compose/docker-compose.prod.yml config`.

The workflow also uses Docker Buildx cache, OCI image labels, production concurrency, the `production` GitHub Environment, manual stable-router verification, and a GitHub Actions summary.


The manual path checks:

```bash
curl -f http://$EC2_HOST
curl -f http://$EC2_HOST/api/health
```

The server-side verification script retries these checks and starts automatic rollback when the initial legacy deployment fails. Blue/Green deployment is not implemented.


## EC2 Repo Bootstrap

The manual bootstrap workflow runs `scripts/ensure-ec2-repo.sh` over SSH before it runs `scripts/deploy.sh`.

The bootstrap script checks whether `/home/ubuntu/Zero-Downtime-Deployment-System/.git` exists for the `ubuntu` user. If it exists, the script validates the checkout but deliberately leaves it unchanged. If it does not exist and the target directory is empty or missing, the script clones `https://github.com/jackpac2/Zero-Downtime-Deployment-System.git` into the ubuntu user's app directory.

The safety-aware deployment launcher performs fetching, allowed-history validation, and exact checkout only after acquiring the production lock. EC2 still does not build images; it pulls and runs the exact GHCR images for the requested commit.

## Compose Project Naming

Production Compose uses the explicit project name `zero-downtime`. The production Compose file does not hardcode `container_name`, so Docker Compose can create and reconcile project-scoped containers such as `zero-downtime-backend-1` across repeated deployments.

Older deployments used fixed names like `zero-downtime-backend`. The deploy script includes targeted one-time cleanup for those legacy names only when they belong to another Compose project or a manual container. This prevents name conflicts while keeping repeated deployments idempotent.
