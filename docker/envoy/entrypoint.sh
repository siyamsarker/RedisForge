#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_DIR="/etc/envoy/templates"
CONFIG_PATH="/etc/envoy/envoy.yaml"

err() {
  echo "[redisforge-envoy-entrypoint] $*" >&2
}

require_secret() {
  local var="$1"
  local value="${!var:-}"
  if [[ -z "$value" ]]; then
    err "Environment variable ${var} must be set"
    exit 1
  fi
  if [[ "$value" == *"CHANGE_ME"* ]]; then
    err "Environment variable ${var} still contains the placeholder value. Set a strong secret."
    exit 1
  fi
}

export ENVOY_ADMIN_PORT="${ENVOY_ADMIN_PORT:-9901}"
export ENVOY_LISTENER_PORT="${ENVOY_LISTENER_PORT:-6379}"
export ENVOY_CLUSTER_REFRESH_SECONDS="${ENVOY_CLUSTER_REFRESH_SECONDS:-10}"
export ENVOY_MAX_CONNECTIONS="${ENVOY_MAX_CONNECTIONS:-10000}"
export ENVOY_MAX_PENDING_REQUESTS="${ENVOY_MAX_PENDING_REQUESTS:-10000}"
export ENVOY_RETRY_ATTEMPTS="${ENVOY_RETRY_ATTEMPTS:-3}"
export ENVOY_TLS_ENABLED="${ENVOY_TLS_ENABLED:-true}"
export ENVOY_TLS_CERT_PATH="${ENVOY_TLS_CERT_PATH:-/etc/envoy/certs/server.crt}"
export ENVOY_TLS_KEY_PATH="${ENVOY_TLS_KEY_PATH:-/etc/envoy/certs/server.key}"
export REDIS_PORT="${REDIS_PORT:-6379}"

export REDIS_MASTER_1_HOST="${REDIS_MASTER_1_HOST:-redis-master-1}"
export REDIS_MASTER_2_HOST="${REDIS_MASTER_2_HOST:-redis-master-2}"
export REDIS_MASTER_3_HOST="${REDIS_MASTER_3_HOST:-redis-master-3}"

export REDIS_ACL_USER="${REDIS_ACL_USER:-app_user}"

require_secret REDIS_REQUIREPASS

if [[ "${ENVOY_TLS_ENABLED}" == "true" ]]; then
  if [[ ! -f "${ENVOY_TLS_CERT_PATH}" ]] || [[ ! -f "${ENVOY_TLS_KEY_PATH}" ]]; then
    err "TLS is enabled but certificate/key not found (${ENVOY_TLS_CERT_PATH}, ${ENVOY_TLS_KEY_PATH})"
    exit 1
  fi
else
  err "Disabling TLS is not supported in production builds. Set ENVOY_TLS_ENABLED=true."
  exit 1
fi

render() {
  envsubst < "${TEMPLATE_DIR}/envoy.yaml" > "$CONFIG_PATH"
}

render

exec /usr/bin/dumb-init -- "$@"

