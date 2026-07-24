#!/usr/bin/env bash

# Shared router transaction. Callers set APP_DIR, DOCKER, ROUTER_COMPOSE,
# ROUTER_CONFIG and ROUTER_RENDERER before invoking these functions.
ROUTER_SWITCH_DIR=""
ROUTER_CONFIG_BACKUP=""
ROUTER_CONTAINER=""
ROUTER_SWITCH_PREPARED=false
ROUTER_SWITCH_APPLIED=false

router_switch_cleanup() {
  [ -z "$ROUTER_SWITCH_DIR" ] || [ ! -d "$ROUTER_SWITCH_DIR" ] || rm -rf -- "$ROUTER_SWITCH_DIR"
}

router_container_id() {
  local id
  id="$("${ROUTER_COMPOSE[@]}" ps -q nginx)"
  [ -n "$id" ] && [ "$(printf '%s\n' "$id" | sed '/^$/d' | wc -l | tr -d '[:space:]')" = 1 ] || {
    echo "Expected exactly one running stable-router Nginx container." >&2; return 1;
  }
  printf '%s\n' "$id"
}

render_and_validate_router_candidate() {
  local target="$1" candidate
  ROUTER_SWITCH_DIR="$(mktemp -d "${APP_DIR}/.deploy/router-switch.XXXXXX")"
  candidate="${ROUTER_SWITCH_DIR}/candidate.conf"
  ROUTER_CONFIG_BACKUP="${ROUTER_SWITCH_DIR}/previous.conf"
  "$ROUTER_RENDERER" "$target" > "$candidate" || return 1
  cp -p -- "$ROUTER_CONFIG" "$ROUTER_CONFIG_BACKUP" || return 1
  echo "Router validation: target=${target}"
  "${DOCKER[@]}" run --rm --network zero-downtime-router \
    --volume "${candidate}:/etc/nginx/conf.d/default.conf:ro" \
    nginx:1.27-alpine nginx -t || return 1
  ROUTER_CONTAINER="$(router_container_id)" || return 1
  "${DOCKER[@]}" exec "$ROUTER_CONTAINER" mkdir -p /etc/nginx/blue-green || return 1
  "${DOCKER[@]}" cp "$candidate" "${ROUTER_CONTAINER}:/etc/nginx/blue-green/candidate.conf.tmp" || return 1
  "${DOCKER[@]}" exec "$ROUTER_CONTAINER" sh -ec '
    if [ -f /etc/nginx/blue-green/original-main.conf ]; then
      cp /etc/nginx/blue-green/original-main.conf /etc/nginx/blue-green/validation-main.conf
    else
      cp /etc/nginx/nginx.conf /etc/nginx/blue-green/validation-main.conf
    fi
    sed -i "s@include /etc/nginx/conf.d/\\*.conf;@include /etc/nginx/blue-green/candidate.conf.tmp;@" /etc/nginx/blue-green/validation-main.conf
    nginx -t -c /etc/nginx/blue-green/validation-main.conf
  ' || return 1
  ROUTER_SWITCH_PREPARED=true
}

apply_router_candidate() {
  local candidate="${ROUTER_SWITCH_DIR}/candidate.conf" host_tmp="${ROUTER_CONFIG}.tmp.$$"
  [ "$ROUTER_SWITCH_PREPARED" = true ] || { echo "Router candidate was not validated." >&2; return 1; }
  cp -p -- "$candidate" "$host_tmp" || return 1
  mv -f -- "$host_tmp" "$ROUTER_CONFIG" || return 1
  ROUTER_SWITCH_APPLIED=true
  if ! "${DOCKER[@]}" exec "$ROUTER_CONTAINER" sh -ec '
    if [ -f /etc/nginx/blue-green/active.conf ]; then
      cp /etc/nginx/blue-green/active.conf /etc/nginx/blue-green/previous.conf.tmp
    else
      cp /etc/nginx/conf.d/default.conf /etc/nginx/blue-green/previous.conf.tmp
    fi
    mv /etc/nginx/blue-green/previous.conf.tmp /etc/nginx/blue-green/previous.conf
    mv /etc/nginx/blue-green/candidate.conf.tmp /etc/nginx/blue-green/active.conf
    if [ ! -f /etc/nginx/blue-green/original-main.conf ]; then
      cp /etc/nginx/nginx.conf /etc/nginx/blue-green/original-main.conf
    fi
    cp /etc/nginx/blue-green/original-main.conf /etc/nginx/blue-green/main.conf.tmp
    sed -i "s@include /etc/nginx/conf.d/\\*.conf;@include /etc/nginx/blue-green/active.conf;@" /etc/nginx/blue-green/main.conf.tmp
    mv /etc/nginx/blue-green/main.conf.tmp /etc/nginx/nginx.conf
    nginx -t
  '; then
    restore_previous_router || true
    return 1
  fi
  echo "Traffic switch: reloading stable Nginx."
  if ! "${DOCKER[@]}" exec "$ROUTER_CONTAINER" nginx -s reload; then
    restore_previous_router
    return 1
  fi
  ROUTER_SWITCH_APPLIED=true
}

restore_previous_router() {
  local host_tmp="${ROUTER_CONFIG}.restore.$$" status=0
  [ -n "$ROUTER_CONFIG_BACKUP" ] && [ -f "$ROUTER_CONFIG_BACKUP" ] || {
    echo "Previous router configuration is unavailable." >&2; return 1;
  }
  cp -p -- "$ROUTER_CONFIG_BACKUP" "$host_tmp" || return 1
  mv -f -- "$host_tmp" "$ROUTER_CONFIG" || return 1
  if [ -n "$ROUTER_CONTAINER" ]; then
    "${DOCKER[@]}" exec "$ROUTER_CONTAINER" sh -ec '
      test -f /etc/nginx/blue-green/previous.conf
      cp /etc/nginx/blue-green/previous.conf /etc/nginx/blue-green/active.conf.tmp
      mv /etc/nginx/blue-green/active.conf.tmp /etc/nginx/blue-green/active.conf
      nginx -t
    ' || status=1
    "${DOCKER[@]}" exec "$ROUTER_CONTAINER" nginx -s reload || status=1
  fi
  ROUTER_SWITCH_APPLIED=false
  return "$status"
}
