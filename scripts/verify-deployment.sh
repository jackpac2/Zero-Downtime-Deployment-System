#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "Usage: $0 <app-url>" >&2
  exit 1
fi

APP_URL="${1%/}"
ATTEMPTS=12
DELAY_SECONDS=5

check_url() {
  local name="$1"
  local url="$2"

  echo "Checking ${name}: ${url}"
  curl -fsS "$url" >/dev/null
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "Verification attempt ${attempt}/${ATTEMPTS}"

  if check_url "frontend" "${APP_URL}/" && check_url "backend" "${APP_URL}/api/health"; then
    echo "Deployment verification passed."
    exit 0
  fi

  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    echo "Deployment verification failed; retrying in ${DELAY_SECONDS}s."
    sleep "$DELAY_SECONDS"
  fi
done

echo "Deployment verification failed after ${ATTEMPTS} attempts." >&2
exit 1
