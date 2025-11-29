#!/usr/bin/env bash

################################################################################
# RedisForge - Exporter Setup Script
# Deploys redis_exporter and node_exporter for monitoring
################################################################################

set -euo pipefail

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

deploy_redis_exporter() {
  log "Deploying Redis Exporter..."
  local exporter_port="${REDIS_EXPORTER_PORT:-9121}"
  
  # Stop existing container if running
  docker stop redis-exporter 2>/dev/null || true
  docker rm redis-exporter 2>/dev/null || true
  
  # Determine Redis address
  # Use container name if Redis is in Docker, otherwise use host/port from env
  if docker ps | grep -q "redis-master"; then
    REDIS_ADDR="redis-master:${REDIS_PORT:-6379}"
  else
    REDIS_ADDR="${REDIS_CONTAINER_NAME:-127.0.0.1}:${REDIS_PORT:-6379}"
  fi
  
  # Build docker run command
  DOCKER_CMD=(
    docker run -d
    --name redis-exporter
    --hostname redis-exporter
    --restart unless-stopped
    --network host
    -e REDIS_ADDR="${REDIS_ADDR}"
    -e REDIS_PASSWORD="${REDIS_REQUIREPASS}"
    -e REDIS_USER="${REDIS_ACL_USER:-app_user}"
  )
  
  # Run redis_exporter container
  log "Starting Redis Exporter container..."
  "${DOCKER_CMD[@]}" \
    "${REDIS_EXPORTER_IMAGE:-oliver006/redis_exporter:v1.80.1}" \
    --redis.addr="${REDIS_ADDR}" \
    --redis.password="${REDIS_REQUIREPASS}" \
    --redis.user="${REDIS_ACL_USER:-app_user}" \
    --web.listen-address=":${exporter_port}" \
    --web.telemetry-path="/metrics"
  
  log "Redis Exporter deployed successfully!"
  info "Metrics endpoint: http://localhost:${exporter_port}/metrics"
  
  info "Configure Prometheus to scrape this endpoint directly."
}

deploy_node_exporter() {
  log "Deploying Node Exporter..."
  
  # Stop existing container if running
  docker stop node-exporter 2>/dev/null || true
  docker rm node-exporter 2>/dev/null || true
  
  # Run node_exporter container
  log "Starting Node Exporter container..."
  docker run -d \
    --name node-exporter \
    --hostname node-exporter \
    --restart unless-stopped \
    --net="host" \
    --pid="host" \
    -p "${NODE_EXPORTER_PORT:-9100}:9100" \
    -v "/:/host:ro,rslave" \
    "${NODE_EXPORTER_IMAGE:-prom/node-exporter:v1.8.2}" \
    --path.rootfs=/host \
    --web.listen-address=":${NODE_EXPORTER_PORT:-9100}"
  
  log "Node Exporter deployed successfully!"
  info "Metrics endpoint: http://localhost:${NODE_EXPORTER_PORT:-9100}/metrics"
}

print_prometheus_config() {
  cat << EOF

================================================================================
PROMETHEUS PULL MONITORING SETUP
================================================================================

RedisForge now relies on native Prometheus scraping:

  Prometheus → redis_exporter (9121) / node_exporter (9100) / Envoy (9901)

STEP 1: Ensure exporters are running on every Redis node (already handled by this script).

STEP 2: Add the exporters to your Prometheus config. Example:

scrape_configs:
  - job_name: 'redisforge-redis'
    metrics_path: /metrics
    static_configs:
      - targets:
          - '<redis-node-1>:${REDIS_EXPORTER_PORT:-9121}'
          - '<redis-node-2>:${REDIS_EXPORTER_PORT:-9121}'
        labels:
          role: redis

  - job_name: 'redisforge-node'
    metrics_path: /metrics
    static_configs:
      - targets:
          - '<redis-node-1>:${NODE_EXPORTER_PORT:-9100}'
          - '<redis-node-2>:${NODE_EXPORTER_PORT:-9100}'
        labels:
          role: system

  - job_name: 'redisforge-envoy'
    metrics_path: /stats/prometheus
    static_configs:
      - targets:
          - '<envoy-host>:${ENVOY_ADMIN_PORT:-9901}'
        labels:
          role: envoy

Replace the placeholder hostnames with the private IPs or DNS names of your instances.

STEP 3: Reload Prometheus:
  curl -X POST http://<prometheus-host>:9090/-/reload

================================================================================
VERIFICATION
================================================================================

Check targets:
  curl http://<prometheus-host>:9090/api/v1/targets | jq '.data.activeTargets'

Run sample queries:
  curl "http://<prometheus-host>:9090/api/v1/query?query=redis_up"
  curl "http://<prometheus-host>:9090/api/v1/query?query=node_load1"

Grafana dashboard:
  monitoring/grafana/dashboards/redisforge-dashboard.json

================================================================================

EOF
}

main() {
  require docker
  load_env

  log "Starting exporter deployment..."
  
  deploy_redis_exporter
  deploy_node_exporter
  
  log "All exporters deployed successfully!"
  echo ""
  info "Verify exporters are running:"
  info "  docker ps | grep exporter"
  echo ""
  info "Check metrics endpoints:"
  info "  curl http://localhost:${REDIS_EXPORTER_PORT:-9121}/metrics"
  info "  curl http://localhost:${NODE_EXPORTER_PORT:-9100}/metrics"
  echo ""
  
  print_prometheus_config
}

main "$@"
