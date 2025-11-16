#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_DIR="/etc/redis/templates"
CONFIG_PATH="/etc/redis/redis.conf"
ACL_PATH="/etc/redis/users.acl"

err() {
  echo "[redisforge-entrypoint] $*" >&2
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

# Export defaults for optional settings
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_CLUSTER_ANNOUNCE_PORT="${REDIS_CLUSTER_ANNOUNCE_PORT:-$REDIS_PORT}"
export REDIS_CLUSTER_ANNOUNCE_BUS_PORT="${REDIS_CLUSTER_ANNOUNCE_BUS_PORT:-16379}"
export REDIS_AOF_ENABLED="${REDIS_AOF_ENABLED:-yes}"
export REDIS_APPEND_FSYNC="${REDIS_APPEND_FSYNC:-everysec}"
export REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-8gb}"
export REDIS_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"
export REDIS_LOGLEVEL="${REDIS_LOGLEVEL:-notice}"

export REDIS_ACL_USER="${REDIS_ACL_USER:-app_user}"
export REDIS_READONLY_USER="${REDIS_READONLY_USER:-readonly_user}"
export REDIS_MONITOR_USER="${REDIS_MONITOR_USER:-monitor_user}"
export REDIS_REPLICATION_USER="${REDIS_REPLICATION_USER:-replication_user}"

# Auto-detect announce IP if not provided
if [[ -z "${REDIS_CLUSTER_ANNOUNCE_IP:-}" ]]; then
  export REDIS_CLUSTER_ANNOUNCE_IP
  if command -v hostname >/dev/null 2>&1; then
    REDIS_CLUSTER_ANNOUNCE_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$REDIS_CLUSTER_ANNOUNCE_IP" ]] && command -v getent >/dev/null 2>&1; then
    REDIS_CLUSTER_ANNOUNCE_IP=$(getent hosts "$(hostname)" | awk 'NR==1 {print $1}')
  fi
  if [[ -z "$REDIS_CLUSTER_ANNOUNCE_IP" ]]; then
    REDIS_CLUSTER_ANNOUNCE_IP="127.0.0.1"
  fi
fi

# Secrets must be supplied
require_secret REDIS_REQUIREPASS
require_secret REDIS_ACL_PASS
require_secret REDIS_READONLY_PASS
require_secret REDIS_MONITOR_PASS
require_secret REDIS_REPLICATION_PASS

export REDIS_REQUIREPASS REDIS_ACL_PASS REDIS_READONLY_PASS REDIS_MONITOR_PASS REDIS_REPLICATION_PASS

render() {
  local template="$1"
  local destination="$2"
  envsubst < "$template" > "$destination"
}

render "${TEMPLATE_DIR}/redis.conf" "$CONFIG_PATH"
render "${TEMPLATE_DIR}/users.acl" "$ACL_PATH"

chmod 600 "$ACL_PATH"

exec /sbin/tini -- "$@"

