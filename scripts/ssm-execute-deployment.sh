#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 9 ]; then
  echo "Usage: $0 <deploy-user> <app-dir> <sha> <public-ip> <aws-region> <username-param> <token-param> <webhook-param> <coordinator>" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "The SSM deployment wrapper must start with root authority." >&2
  exit 1
fi

DEPLOY_USER="$1"
APP_DIR="$2"
DEPLOY_SHA="$3"
PUBLIC_IP="$4"
AWS_REGION_VALUE="$5"
GHCR_USERNAME_PARAMETER="$6"
GHCR_TOKEN_PARAMETER="$7"
DISCORD_WEBHOOK_PARAMETER="$8"
COORDINATOR="$9"

[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo "Invalid deployment user." >&2; exit 1; }
[[ "$DEPLOY_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Invalid deployment SHA." >&2; exit 1; }
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Invalid inferred EC2 public IPv4 address." >&2; exit 1; }
[[ "$AWS_REGION_VALUE" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || { echo "Invalid AWS region." >&2; exit 1; }
id "$DEPLOY_USER" >/dev/null 2>&1 || { echo "Deployment user does not exist: ${DEPLOY_USER}" >&2; exit 1; }
[ -d "$APP_DIR/.git" ] || { echo "Deployment repository is missing: ${APP_DIR}" >&2; exit 1; }
[ -f "$COORDINATOR" ] || { echo "Deployment coordinator is missing: ${COORDINATOR}" >&2; exit 1; }

read_secure_parameter() {
  local parameter_name="$1"
  if [ -z "$parameter_name" ]; then
    return 0
  fi
  [[ "$parameter_name" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "Invalid secure parameter name." >&2; return 1; }
  aws ssm get-parameter \
    --region "$AWS_REGION_VALUE" \
    --name "$parameter_name" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

GHCR_USERNAME="$(read_secure_parameter "$GHCR_USERNAME_PARAMETER")"
GHCR_TOKEN="$(read_secure_parameter "$GHCR_TOKEN_PARAMETER")"
DISCORD_WEBHOOK_URL="$(read_secure_parameter "$DISCORD_WEBHOOK_PARAMETER")"
export GHCR_USERNAME GHCR_TOKEN DISCORD_WEBHOOK_URL

exec sudo \
  --preserve-env=GHCR_USERNAME,GHCR_TOKEN,DISCORD_WEBHOOK_URL \
  -u "$DEPLOY_USER" \
  -H \
  -- bash "$COORDINATOR" "$APP_DIR" "$DEPLOY_SHA" "$PUBLIC_IP"
