# Zero Downtime Deployment System

## Project Structure

The application source code is shared between development and production:

- `frontend/` contains the frontend application and Dockerfile.
- `backend/` contains the backend application and Dockerfile.
- `nginx/` contains the Nginx reverse proxy configuration.
- `compose/docker-compose.dev.yml` is for local development and manual testing.
- `compose/docker-compose.prod.yml` is for production deployment on EC2.
- `scripts/deploy.sh` is the EC2 deployment entrypoint.
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

- Pulls the latest `Main` branch files.
- Exports `IMAGE_TAG=<git-sha>`.
- Creates `.deploy/` if needed.
- Copies `.deploy/current.sha` to `.deploy/previous.sha` before deployment.
- Runs `docker compose -f compose/docker-compose.prod.yml pull`.
- Runs `docker compose -f compose/docker-compose.prod.yml up -d`.
- Removes unused old images with `docker image prune -f`.
- Shows running containers with `docker ps`.
- Writes `.deploy/current.sha` only after Compose deployment succeeds.

Health checks, automatic rollback, and alerts are intentionally not implemented yet. The `.deploy/current.sha` and `.deploy/previous.sha` files only prepare the version tracking foundation for Phase 7.

## Ignored Deployment State

`.deploy/` is ignored by Git because it is server-side deployment state, not source code.

It may contain:

- `current.sha`
- `previous.sha`

These files should stay on EC2 and should not be committed to GitHub.

## Phase 6 CI/CD Flow

The intended Phase 6 production flow is:

1. Developer pushes to `Main`.
2. GitHub Actions builds frontend and backend Docker images.
3. GitHub Actions tags images with the full Git SHA, short Git SHA, and `latest`.
4. GitHub Actions pushes images to GHCR.
5. GitHub Actions connects to EC2 over SSH.
6. GitHub Actions runs `./scripts/deploy.sh <git-sha>`.
7. EC2 pulls and starts the exact full-SHA image versions.

## Required GitHub Secrets

Required repository secrets:

| Secret | Expected value |
| --- | --- |
| `EC2_HOST` | Your EC2 public DNS name or public IP address |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Private SSH key that can connect to the EC2 instance |
| `EC2_APP_DIR` | `/home/ubuntu/Zero-Downtime-Deployment-System` |

Optional secrets for private GHCR packages:

| Secret | Purpose |
| --- | --- |
| `GHCR_USERNAME` | GitHub username used by EC2 for GHCR login |
| `GHCR_TOKEN` | GitHub Personal Access Token with package read access |

If the GHCR packages are public, EC2 does not need GHCR login. If they are private, store a GitHub Personal Access Token with package read access as `GHCR_TOKEN`.

## Required EC2 Setup

The EC2 instance should already have:

- Ubuntu user: `ubuntu`
- Repository cloned at `/home/ubuntu/Zero-Downtime-Deployment-System`
- Docker installed
- Docker Compose v2 installed and available as `docker compose`
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
- Production Compose: `docker compose -f compose/docker-compose.prod.yml config`.

The workflow also uses Docker Buildx cache, OCI image labels, production deployment concurrency, the `production` GitHub Environment, path filters, post-deployment smoke tests, and a GitHub Actions deployment summary.

The smoke tests check:

```bash
curl -f http://$EC2_HOST
curl -f http://$EC2_HOST/api/health
```

These smoke tests are simple Phase 6 checks only. Full health-check retry logic, rollback, alerts, and blue-green deployment remain Phase 7 work.
