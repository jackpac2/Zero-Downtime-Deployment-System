#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
TEMPLATE="${ROOT_DIR}/nginx/router.conf.template"
if [ "$#" -ne 1 ]; then echo "Usage: $0 <legacy|blue|green>" >&2; exit 1; fi
case "$1" in
  legacy) frontend_host=app-frontend; backend_host=app-backend ;;
  blue) frontend_host=blue-frontend; backend_host=blue-backend ;;
  green) frontend_host=green-frontend; backend_host=green-backend ;;
  *) echo "Router target is invalid. Expected exactly legacy, blue, or green." >&2; exit 1 ;;
esac
[ -f "$TEMPLATE" ] || { echo "Router template is missing: ${TEMPLATE}" >&2; exit 1; }
sed -e "s/__FRONTEND_HOST__/${frontend_host}/g" -e "s/__BACKEND_HOST__/${backend_host}/g" "$TEMPLATE"
