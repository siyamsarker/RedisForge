#!/usr/bin/env bash

################################################################################
# RedisForge - Direct Docker Deployment Script (No Docker Compose)
# Deploys Redis cluster or Envoy proxy using native Docker commands on EC2
#
# COMPATIBILITY:
# - Amazon Linux 2023
# - Ubuntu 24.04 LTS (Noble Numbat)
# - Docker Engine 20.10+ or Docker CE 24.0+
#
# UBUNTU 24.04 REQUIREMENTS:
# - sudo apt install docker.io docker-compose-v2 git redis-tools curl jq
# - sudo systemctl enable --now docker
# - sudo usermod -aG docker $USER && newgrp docker
################################################################################

set -euo pipefail

ROLE=${1:-}
if [[ -z "${ROLE}" ]]; then
  echo "Usage: $0 [redis|envoy|monitoring]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

load_env() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  else
    error ".env file not found. Please create it from env.example"
    exit 1
  fi
}

require() {
  command -v "$1" >/dev/null 2>&1 || { error "Missing dependency: $1"; exit 1; }
}

deploy_redis() {
  log "Deploying Redis master node..."
  
  # Create directories
  mkdir -p "${REPO_ROOT}/data/redis" "${REPO_ROOT}/logs/redis"
  
  # Build Redis image if needed
  if ! docker images | grep -q "redisforge/redis"; then
    log "Building Redis image..."
    docker build -t redisforge/redis:8.2 -f "${REPO_ROOT}/docker/redis/Dockerfile" "${REPO_ROOT}"
  fi
  
  # Stop existing container if running
  docker stop redis-master 2>/dev/null || true
  docker rm redis-master 2>/dev/null || true
  
  # Run Redis container
  log "Starting Redis container..."
  docker run -d \
    --name redis-master \
    --hostname redis-master \
    --restart unless-stopped \
    --network host \
    --ulimit nofile=100000:100000 \
    -p "${REDIS_PORT:-6379}:${REDIS_PORT:-6379}" \
    -p "${REDIS_CLUSTER_BUS_PORT:-16379}:${REDIS_CLUSTER_BUS_PORT:-16379}" \
    -e REDIS_PORT="${REDIS_PORT:-6379}" \
    -e REDIS_CLUSTER_ANNOUNCE_IP="${REDIS_CLUSTER_ANNOUNCE_IP}" \
    -e REDIS_CLUSTER_ANNOUNCE_PORT="${REDIS_CLUSTER_ANNOUNCE_PORT:-6379}" \
    -e REDIS_CLUSTER_ANNOUNCE_BUS_PORT="${REDIS_CLUSTER_ANNOUNCE_BUS_PORT:-16379}" \
    -e REDIS_AOF_ENABLED="${REDIS_AOF_ENABLED:-yes}" \
    -e REDIS_APPEND_FSYNC="${REDIS_APPEND_FSYNC:-everysec}" \
    -e REDIS_REQUIREPASS="${REDIS_REQUIREPASS}" \
    -e REDIS_ACL_USER="${REDIS_ACL_USER:-app_user}" \
    -e REDIS_ACL_PASS="${REDIS_ACL_PASS}" \
    -e REDIS_READONLY_USER="${REDIS_READONLY_USER:-readonly_user}" \
    -e REDIS_READONLY_PASS="${REDIS_READONLY_PASS}" \
    -e REDIS_MONITOR_USER="${REDIS_MONITOR_USER:-monitor_user}" \
    -e REDIS_MONITOR_PASS="${REDIS_MONITOR_PASS}" \
    -e REDIS_REPLICATION_USER="${REDIS_REPLICATION_USER:-replication_user}" \
    -e REDIS_REPLICATION_PASS="${REDIS_REPLICATION_PASS}" \
    -e REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-8gb}" \
    -e REDIS_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}" \
    -e REDIS_LOGLEVEL="${REDIS_LOGLEVEL:-notice}" \
    -v "${REPO_ROOT}/data/redis:/data" \
    -v "${REPO_ROOT}/logs/redis:/var/log/redis" \
    -v "${REPO_ROOT}/config/redis/redis.conf:/etc/redis/templates/redis.conf:ro" \
    -v "${REPO_ROOT}/config/redis/users.acl:/etc/redis/templates/users.acl:ro" \
    redisforge/redis:8.2
  
  log "Redis deployed successfully!"
  info "Check status: docker ps | grep redis-master"
  info "View logs: docker logs redis-master"
  
  # Wait for Redis to be healthy
  log "Waiting for Redis to become healthy..."
  local max_attempts=30
  local attempt=1
  while (( attempt <= max_attempts )); do
    if docker exec redis-master redis-cli -a "${REDIS_REQUIREPASS}" ping 2>/dev/null | grep -q PONG; then
      log "✓ Redis is healthy"
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      info "Still waiting... (attempt $attempt/$max_attempts)"
    fi
    sleep 2
    (( attempt++ ))
  done
  
  error "Redis failed to become healthy after $max_attempts attempts"
  error "Check logs: docker logs redis-master"
  exit 1
}

deploy_envoy() {
  log "Deploying Envoy proxy..."
  
  # Build Envoy image if needed
  if ! docker images | grep -q "redisforge/envoy"; then
    log "Building Envoy image..."
    docker build -t redisforge/envoy:latest -f "${REPO_ROOT}/docker/envoy/Dockerfile" "${REPO_ROOT}"
  fi
  
  # Stop existing container if running
  docker stop envoy-proxy 2>/dev/null || true
  docker rm envoy-proxy 2>/dev/null || true
  
  # Validate TLS certificates exist
  ENVOY_TLS_CERT_PATH="${ENVOY_TLS_CERT_PATH:-${REPO_ROOT}/config/tls/prod/server.crt}"
  ENVOY_TLS_KEY_PATH="${ENVOY_TLS_KEY_PATH:-${REPO_ROOT}/config/tls/prod/server.key}"
  ENVOY_TLS_DIR=$(dirname "${ENVOY_TLS_CERT_PATH}")
  
  if [[ ! -f "${ENVOY_TLS_CERT_PATH}" ]] || [[ ! -f "${ENVOY_TLS_KEY_PATH}" ]]; then
    error "TLS certificates not found!"
    error "Expected: ${ENVOY_TLS_CERT_PATH} and ${ENVOY_TLS_KEY_PATH}"
    error "Generate certificates with: ./scripts/generate-certs.sh ${ENVOY_TLS_DIR}"
    exit 1
  fi
  
  # Create certs directory in container mount point
  mkdir -p "${ENVOY_TLS_DIR}"
  
  # Run Envoy container
  log "Starting Envoy container..."
  docker run -d \
    --name envoy-proxy \
    --hostname envoy-proxy \
    --restart unless-stopped \
    --network host \
    --ulimit nofile=100000:100000 \
    -p "${ENVOY_LISTENER_PORT:-6379}:6379" \
    -p "${ENVOY_ADMIN_PORT:-9901}:9901" \
    -e REDIS_REQUIREPASS="${REDIS_REQUIREPASS}" \
    -e REDIS_ACL_USER="${REDIS_ACL_USER:-app_user}" \
    -e REDIS_PORT="${REDIS_PORT:-6379}" \
    -e REDIS_MASTER_1_HOST="${REDIS_MASTER_1_HOST:-redis-master-1}" \
    -e REDIS_MASTER_2_HOST="${REDIS_MASTER_2_HOST:-redis-master-2}" \
    -e REDIS_MASTER_3_HOST="${REDIS_MASTER_3_HOST:-redis-master-3}" \
    -e ENVOY_ADMIN_PORT="${ENVOY_ADMIN_PORT:-9901}" \
    -e ENVOY_LISTENER_PORT="${ENVOY_LISTENER_PORT:-6379}" \
    -e ENVOY_CLUSTER_REFRESH_SECONDS="${ENVOY_CLUSTER_REFRESH_SECONDS:-10}" \
    -e ENVOY_MAX_CONNECTIONS="${ENVOY_MAX_CONNECTIONS:-10000}" \
    -e ENVOY_MAX_PENDING_REQUESTS="${ENVOY_MAX_PENDING_REQUESTS:-10000}" \
    -e ENVOY_RETRY_ATTEMPTS="${ENVOY_RETRY_ATTEMPTS:-3}" \
    -e ENVOY_TLS_ENABLED="${ENVOY_TLS_ENABLED:-true}" \
    -e ENVOY_TLS_CERT_PATH="/etc/envoy/certs/server.crt" \
    -e ENVOY_TLS_KEY_PATH="/etc/envoy/certs/server.key" \
    -v "${REPO_ROOT}/config/envoy/envoy.yaml:/etc/envoy/templates/envoy.yaml:ro" \
    -v "${ENVOY_TLS_DIR}:/etc/envoy/certs:ro" \
    redisforge/envoy:latest
  
  log "Envoy deployed successfully!"
  info "Check status: docker ps | grep envoy-proxy"
  info "Admin interface: http://localhost:${ENVOY_ADMIN_PORT:-9901}"
  info "View logs: docker logs envoy-proxy"
  
  # Wait for Envoy to be healthy
  log "Waiting for Envoy to become healthy..."
  local max_attempts=30
  local attempt=1
  while (( attempt <= max_attempts )); do
    if curl -sf "http://localhost:${ENVOY_ADMIN_PORT:-9901}/ready" >/dev/null 2>&1; then
      log "✓ Envoy is healthy"
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      info "Still waiting... (attempt $attempt/$max_attempts)"
    fi
    sleep 2
    (( attempt++ ))
  done
  
  error "Envoy failed to become healthy after $max_attempts attempts"
  error "Check logs: docker logs envoy-proxy"
  exit 1
}

deploy_monitoring() {
  log "Deploying monitoring exporters..."
  
  # Use the dedicated exporter setup script
  "${SCRIPT_DIR}/setup-exporters.sh"
  
  log "Exporters deployed successfully!"
  info "Configure your Prometheus to scrape:"
  info "  - Redis Exporter: <host>:${REDIS_EXPORTER_PORT:-9121}"
  info "  - Node Exporter: <host>:${NODE_EXPORTER_PORT:-9100}"
  info "  - Envoy Metrics: <envoy-host>:${ENVOY_ADMIN_PORT:-9901}/stats/prometheus"
}

main() {
  require docker
  load_env

  case "${ROLE}" in
    redis)
      deploy_redis
      ;;
    envoy)
      deploy_envoy
      ;;
    monitoring)
      deploy_monitoring
      ;;
    *)
      error "Unknown role: ${ROLE}"
      exit 1
      ;;
  esac
  
  log "Deployment completed successfully!"
}

main "$@"

