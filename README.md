# Zero Downtime Deployment System

## Project Structure

The application source code is shared between development and production:

- `frontend/` contains the frontend application and Dockerfile.
- `backend/` contains the backend application and Dockerfile.
- `nginx/` contains the Nginx reverse proxy configuration.
- `compose/docker-compose.dev.yml` is for local development and manual testing.
- `compose/docker-compose.prod.yml` is for production deployment on EC2.
- `compose/docker-compose.router.yml` prepares the stable Nginx and notifier project.
- `compose/docker-compose.app-legacy.yml` preserves the currently migrated `zero-downtime-app` definition.
- `compose/docker-compose.app.yml` prepares an isolated Blue or Green frontend/backend candidate.
- `scripts/ensure-ec2-repo.sh` bootstraps the repo into the ubuntu user's EC2 app directory if it is missing.
- `scripts/bootstrap-ec2-host.sh` idempotently installs Ubuntu prerequisites and configures non-sudo Docker access.
- `scripts/deploy.sh` remains the pre-migration legacy deployment entrypoint.
- `scripts/deploy-blue-green.sh` is the stable-router Blue/Green deployment entrypoint.
- `scripts/rollback-blue-green.sh` switches back to the retained opposite color without rebuilding.
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

## Stable Router Blue/Green Topology

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

`compose/docker-compose.router.yml` contains only public Nginx and the deployment notifier. Nginx owns port `80`, mounts the ignored runtime file `.deploy/router/router.conf` read-only, and provides `/router-health` without contacting either application service. The notifier retains `127.0.0.1:9001:4000`, its webhook environment variable, and its health check. `nginx/router.conf` remains the tracked legacy definition; deployment state is never written into the Git checkout.

`compose/docker-compose.app-legacy.yml` contains the live migrated frontend and backend definition. Both remain on the application's project-local default network and join the external `zero-downtime-router` network as `app-frontend` and `app-backend`. Existing migration and verification paths continue using this compatibility file, so the live router target is unchanged.

`compose/docker-compose.app.yml` is the Blue/Green application template. A validated `DEPLOY_COLOR=blue` or `DEPLOY_COLOR=green` selects the isolated project `zero-downtime-blue` or `zero-downtime-green`. The candidates use only `blue-frontend`/`blue-backend` or `green-frontend`/`green-backend` on the shared router network. They publish no host ports and never claim the live `app-frontend` or `app-backend` aliases.

The external network must be created once before either prepared project is started:

```bash
docker network create zero-downtime-router
```

Because the network is declared `external`, normal `docker compose down` operations for either project do not delete it.

The prepared router uses Docker's embedded DNS resolver at `127.0.0.11`. Its `proxy_pass` targets contain variables, so Nginx resolves `app-frontend` and `app-backend` while handling requests instead of resolving each name only when Nginx starts. Results are cached for at most 10 seconds. Recreating an application container can therefore give its alias a new IP without requiring a router restart. While an alias is temporarily unavailable, proxied application requests return an upstream error, but `/router-health` continues returning `200`; Nginx retries DNS resolution and recovers when the alias is available again.

After `.deploy/topology` is `stable-router`, production deployment uses `deploy-blue-green.sh` and color-aware rollback uses `rollback-blue-green.sh`. The legacy `deploy.sh`, `rollback.sh`, and combined Compose file remain available only for pre-migration compatibility. The stable router is reloaded gracefully; it is never recreated by a color switch.

Validate the prepared topology without starting production services:

```bash
export IMAGE_TAG=0000000000000000000000000000000000000000
export DISCORD_WEBHOOK_URL=""

docker compose -p zero-downtime -f compose/docker-compose.prod.yml config
docker compose -p zero-downtime-app -f compose/docker-compose.app-legacy.yml config
DEPLOY_COLOR=blue docker compose -p zero-downtime-blue -f compose/docker-compose.app.yml config
DEPLOY_COLOR=green docker compose -p zero-downtime-green -f compose/docker-compose.app.yml config
docker compose -p zero-downtime-router -f compose/docker-compose.router.yml config
bash scripts/tests/test-router-topology.sh
bash scripts/tests/test-blue-green-preparation.sh
bash scripts/tests/test-router-rendering.sh
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

After migration, use the Blue/Green entrypoint described below. The legacy in-place entrypoint remains only for bootstrap and migration compatibility.

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

Phase 3B uses `active-color`, `candidate-color`, `blue.sha`, and `green.sha`. Color files accept exactly `blue` or `green`; SHA files accept exactly 40 hexadecimal characters. `candidate-color` exists only during an operation and is removed after success or handled failure. `active-color` is written last, only after public verification. No active color is fabricated for the legacy application.

These files should stay on EC2 and should not be committed to GitHub.

## Production CI/CD Transition Flow

During stable-router activation, a push or merge to `Main`:

1. Validates the application, scripts, Compose files, Nginx configuration, migration transaction, and bootstrap safety tests.
2. Builds and publishes frontend, backend, and notifier images tagged with the full SHA and short SHA.
3. Confirms that push-to-Main does not mutate EC2 and that activation requires manual dispatch.
4. Does not contact EC2, deploy the legacy project, or run migration.

The push guard remains intentional: pushes validate, build, and publish images but never mutate EC2. A manual dispatch is the only production activation path.
## Production CI/CD Flow

The production flow is:

1. Developer pushes to `Main`.
2. GitHub Actions validates the safety helpers and builds frontend, backend, and notifier Docker images.
3. GitHub Actions tags images with the full Git SHA and short Git SHA.
4. GitHub Actions pushes images to GHCR.
5. A manual dispatch uses GitHub OIDC to assume the configured AWS IAM role.
6. GitHub Actions resolves the running instance's current public IPv4 address from `EC2_INSTANCE_ID`.
7. GitHub Actions sends commands to the target EC2 managed node with Systems Manager Run Command.
8. EC2 validates and checks out that commit under the shared lock.
9. EC2 pulls, starts, verifies, and records the exact full-SHA image versions.

## Required GitHub Variables and Secrets

Required repository variables:

| Variable | Expected value |
| --- | --- |
| `AWS_REGION` | `us-east-1` |
| `AWS_ROLE_ARN` | IAM role assumed by GitHub Actions through OIDC |
| `EC2_INSTANCE_ID` | SSM-managed EC2 instance ID |

`EC2_DEPLOY_USER` is optional and defaults to `ubuntu`. It identifies the non-root account used for repository, Docker, deployment, migration, verification, state, and lock operations.

`EC2_USER`, `EC2_SSH_KEY`, and `EC2_KNOWN_HOSTS` are no longer used by the workflow.

`EC2_HOST` is no longer a repository secret or pipeline variable. After OIDC authentication, the workflow uses `ec2:DescribeInstances` with `EC2_INSTANCE_ID` and `AWS_REGION`, requires the instance to be running, and exposes the inferred address as the `public_ip` step output. Deployment verification and notifier alerts receive `APP_URL=http://<public-ip>` directly.

`EC2_APP_DIR` is optional. If empty or unset, every bootstrap step uses exactly `/home/ubuntu/Zero-Downtime-Deployment-System`.

Optional repository secrets:

| Secret | Purpose |
| --- | --- |
| `EC2_APP_DIR` | Custom absolute checkout path; defaults to `/home/ubuntu/Zero-Downtime-Deployment-System` |
| `GHCR_USERNAME` | GitHub username used by EC2 for GHCR login |
| `GHCR_TOKEN` | GitHub Personal Access Token with package read access |
| `DISCORD_WEBHOOK_URL` | Webhook used by the notifier; may be empty |

If the GHCR packages are public, EC2 does not need GHCR login. If they are private, store a GitHub Personal Access Token with package read access as `GHCR_TOKEN`.

The manual workflow copies non-empty GHCR and webhook secrets into uniquely named, short-lived Parameter Store `SecureString` values. The SSM root wrapper retrieves them without printing them, passes them to the deployment user through the process environment, and the workflow deletes the parameters in an `always()` cleanup step. The GitHub OIDC role therefore needs narrowly scoped `ssm:PutParameter` and `ssm:DeleteParameter` access to `/zero-downtime-deployment/github-actions/*`. The EC2 instance role needs `ssm:GetParameter` for the same prefix and decryption permission for the selected KMS key.

## One-Time EC2 Bootstrap and Stable-Router Migration

The topology-aware deployment path is manual because it changes production traffic. In GitHub Actions, open **Build and Deploy**, choose **Run workflow** from `Main`, and start the run. No “new instance” checkbox is required: the workflow reads `.deploy/topology`, runs bootstrap/migration first when absent, and otherwise invokes controlled Blue/Green activation.

The EC2 security group must allow public HTTP port 80. Direct port 22 access is not required by the workflow. Port 9001 must not be public; the notifier remains bound to `127.0.0.1` and is checked locally by the SSM command.

The bootstrap helper installs missing Git, curl, AWS CLI, CA certificates, GnuPG, `util-linux` (`flock`), Docker Engine from Docker's signed official Ubuntu apt repository, and Docker Compose v2. It does not upgrade unrelated packages or reboot. It enables Docker and adds the deployment user to the `docker` group if needed. A separate SSM process must then pass `docker info` and `docker compose version` as that user without `sudo` before repository or production mutation.

The workflow prints the resolved application directory once, creates its parent for the deployment user, runs `ensure-ec2-repo.sh`, and uses `deployment-common.sh` to prepare and verify the exact workflow SHA from `origin/Main` under `flock`.

It reads `.deploy/topology` as plain text:

- No marker means fresh or legacy. The workflow calls `deploy.sh`, verifies the combined `zero-downtime` project and `.deploy/current.sha`, then calls `migrate-to-stable-router.sh`.
- Exactly `stable-router` means migration already completed. It skips migration and invokes the controlled Blue/Green deployment for the exact workflow SHA.
- Any other value fails before production mutation.

Legacy is deployed first because migration preflight requires a healthy combined stack whose `current.sha` matches the requested image SHA. `deploy.sh` continues to own legacy Compose, verification, and rollback. The migration script owns network creation, application preparation, legacy shutdown, router startup, transaction cleanup, legacy restoration, and the atomic topology marker.

If migration fails before cutover, it cleans prepared resources. If it fails after legacy shutdown, it stops new resources and attempts to restore and verify legacy. The workflow remains failed even if restoration succeeds. A final-verification failure produces safe status diagnostics without broad workflow cleanup.

Repeated manual runs never repeat migration. A `stable-router` marker selects the Blue/Green controller, while the push guard prevents automatic EC2 mutation. Do not manually run legacy `deploy.sh` or `rollback.sh` after migration.

Final EC2 checks:

```bash
cd /home/ubuntu/Zero-Downtime-Deployment-System
export IMAGE_TAG="$(tr -d '[:space:]' < .deploy/current.sha)"
docker compose -p zero-downtime-app -f compose/docker-compose.app-legacy.yml ps
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
3. Verify the required secrets, then manually dispatch **Build and Deploy** from `Main` for that commit.
4. Monitor prerequisite installation, the fresh-session Docker check, exact-commit preparation, legacy deployment, migration, and final verification.
5. Confirm the summary reports `stable-router` and all health checks passed.

This is a controlled Blue/Green deployment: the inactive color is prepared and verified before the stable router changes target.

## Private Candidate Verification

Once a later phase starts one color, verify it without using the public Nginx route:

```bash
bash scripts/verify-color-candidate.sh blue <full-40-character-image-sha>
bash scripts/verify-color-candidate.sh green <full-40-character-image-sha>
```

The verifier rejects invalid colors and SHAs, requires exactly one running frontend and backend in the expected color project, checks both image revision labels and shared-network aliases, then launches an ephemeral container on `zero-downtime-router` to request the color-specific frontend and backend directly. It publishes no port, changes no state, and contains no router reload or traffic-switch operation.


## Phase 3B Operations

Run a deployment on a stable-router host with:

```bash
./scripts/deploy-blue-green.sh <full-40-character-git-sha>
```

The script requires the shared deployment lock and `stable-router` topology. With no `active-color`, it requires the migrated `zero-downtime-app` to be live, selects Blue deterministically, deploys and privately verifies Blue, validates a rendered Blue router configuration, gracefully reloads Nginx, verifies public frontend, API, and router health, and only then records Blue as active. The legacy application remains running so the first switch can restore `app-frontend` and `app-backend` immediately.

For later deployments, active Blue selects Green and active Green selects Blue. `DEPLOY_COLOR` and `IMAGE_TAG` are supplied explicitly to `compose/docker-compose.app.yml`; the exact-SHA images are pulled and only the inactive project is reconciled. Candidate services publish no host ports. The previous color remains running as the immediate rollback target.

Router configurations are generated by `scripts/render-router-config.sh`, which accepts only `legacy`, `blue`, or `green`. A temporary Nginx container and the running router validate the candidate before replacement. The controller stages the active configuration inside the existing Nginx container because the router uses a read-only single-file bind mount; this avoids router recreation and permits an atomic internal config install followed by graceful `nginx -s reload`. The ignored host runtime file `.deploy/router/router.conf` is atomically updated for future container recreation.

Hosts upgraded from the initial Phase 3B implementation may have one generated modification to tracked `nginx/router.conf`. Exact-checkout preparation reconciles only that precise case when the file exactly matches the validated `active-color`: it preserves the generated configuration in `.deploy/router/router.conf` and restores the tracked file. Any other tracked modification still fails closed.

If candidate verification or Nginx validation fails, traffic and `active-color` are untouched. If reload or public verification fails, the previous host and internal router configurations are restored, Nginx is reloaded, and the former public target is verified. Candidate diagnostics are retained in Docker logs and `.deploy/failed-candidate.sha`; `candidate-color` is cleared. State is committed in this order: color SHA, `previous.sha`, `current.sha`, then `active-color`; a state-write failure restores the snapshot and prior route.

Rollback does not pull or rebuild:

```bash
./scripts/rollback-blue-green.sh
```

It validates the current color, opposite retained color, retained SHA, running services, private health, router configuration, and public health before writing state. Missing, malformed, stopped, or unhealthy retained state fails closed.

The GitHub Actions **Build and Deploy** workflow uses the same path only for a manual dispatch from `Main`. An absent topology first runs the existing bootstrap and one-time migration, then performs first Blue activation. A push to `Main` only validates, builds, and publishes; it never sends SSM commands or changes EC2.
## Required EC2 Setup

The manual workflow prepares a fresh Ubuntu host, but the instance must already have:

- SSM Agent installed, running, and registered in `us-east-1`.
- An EC2 instance profile that permits Systems Manager managed-node communication.
- HTTPS connectivity to Systems Manager endpoints, directly or through VPC endpoints.
- A deployment user, normally `ubuntu`, with `/home/ubuntu` and passwordless sudo for package, service, directory, and group administration.
- Port `80` open in the EC2 security group.

The GitHub OIDC role must be restricted to this repository's `production` environment and the intended instance. It needs `ec2:DescribeInstances` to resolve the instance state and current public IPv4 address, `ssm:SendCommand` for `AWS-RunShellScript`, command-invocation read access, and the transient SecureString permissions described above. No permanent AWS access key or SSH private key is used.

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
curl -f http://<inferred-public-ip>
curl -f http://<inferred-public-ip>/api/health
```

The server-side verification retries frontend and API checks. Phase 3B additionally verifies router health and automatically restores the previous router target when public verification fails.


## EC2 Repo Bootstrap

The manual bootstrap workflow delivers the pre-repository bootstrap helpers through SSM Run Command, then runs `scripts/ensure-ec2-repo.sh` as the deployment user before it runs `scripts/deploy.sh`.

The bootstrap script checks whether `/home/ubuntu/Zero-Downtime-Deployment-System/.git` exists for the `ubuntu` user. If it exists, the script validates the checkout but deliberately leaves it unchanged. If it does not exist and the target directory is empty or missing, the script clones `https://github.com/jackpac2/Zero-Downtime-Deployment-System.git` into the ubuntu user's app directory.

The safety-aware deployment launcher performs fetching, allowed-history validation, and exact checkout only after acquiring the production lock. EC2 still does not build images; it pulls and runs the exact GHCR images for the requested commit.

Each Run Command is polled to a terminal state. The workflow prints returned standard output, standard error, status, and response code, and fails when the remote invocation is unsuccessful. Systems Manager's inline `get-command-invocation` output is truncated by AWS; CloudWatch Logs or S3 command output can be added later if complete long-form diagnostic logs become necessary.

## Compose Project Naming

Production Compose uses the explicit project name `zero-downtime`. The production Compose file does not hardcode `container_name`, so Docker Compose can create and reconcile project-scoped containers such as `zero-downtime-backend-1` across repeated deployments.

Older deployments used fixed names like `zero-downtime-backend`. The deploy script includes targeted one-time cleanup for those legacy names only when they belong to another Compose project or a manual container. This prevents name conflicts while keeping repeated deployments idempotent.
