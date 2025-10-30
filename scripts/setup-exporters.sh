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
  
  # Stop existing container if running
  docker stop redis-exporter 2>/dev/null || true
  docker rm redis-exporter 2>/dev/null || true
  
  # Determine Redis address (use localhost if not specified)
  REDIS_ADDR="${REDIS_HOST:-localhost}:${REDIS_PORT:-6379}"
  
  # Build docker run command
  DOCKER_CMD=(
    docker run -d
    --name redis-exporter
    --hostname redis-exporter
    --restart unless-stopped
    -p "${REDIS_EXPORTER_PORT:-9121}:9121"
    -e REDIS_ADDR="${REDIS_ADDR}"
    -e REDIS_PASSWORD="${REDIS_REQUIREPASS}"
    -e REDIS_USER="${REDIS_ACL_USER:-default}"
  )
  
  # Run redis_exporter container
  log "Starting Redis Exporter container..."
  "${DOCKER_CMD[@]}" \
    "${REDIS_EXPORTER_IMAGE:-oliver006/redis_exporter:v1.62.0}" \
    --redis.addr="${REDIS_ADDR}" \
    --redis.password="${REDIS_REQUIREPASS}" \
    --redis.user="${REDIS_ACL_USER:-default}" \
    --web.listen-address=":9121" \
    --web.telemetry-path="/metrics"
  
  log "Redis Exporter deployed successfully!"
  info "Metrics endpoint: http://localhost:${REDIS_EXPORTER_PORT:-9121}/metrics"
  
  # If Prometheus Push Gateway is configured, note it
  if [[ -n "${PROMETHEUS_PUSHGATEWAY:-}" ]]; then
    info "Note: Exporters are pull-based. Configure Prometheus to scrape the endpoints."
    info "Or use a separate agent to push metrics to: ${PROMETHEUS_PUSHGATEWAY}"
  fi
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
PUSH-BASED MONITORING SETUP
================================================================================

RedisForge uses PUSH-based monitoring architecture:

  Exporters → Push Script (every ${METRICS_PUSH_INTERVAL:-30}s) → Push Gateway → Prometheus

STEP 1: Configure Push Gateway
Edit .env and set:
  PROMETHEUS_PUSHGATEWAY=http://your-pushgateway:9091
  METRICS_PUSH_INTERVAL=30

STEP 2: Start Metrics Push Service

Option A: Using systemd (recommended for production):
  sudo cp monitoring/systemd/redisforge-metrics-push.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable redisforge-metrics-push
  sudo systemctl start redisforge-metrics-push
  
  # Check status
  sudo systemctl status redisforge-metrics-push
  sudo journalctl -u redisforge-metrics-push -f

Option B: Using screen/tmux (testing):
  screen -S metrics-push
  ./scripts/push-metrics.sh
  # Detach with Ctrl+A, D

Option C: Using nohup (background):
  nohup ./scripts/push-metrics.sh > /var/log/metrics-push.log 2>&1 &

STEP 3: Configure Prometheus to Scrape Push Gateway

Add to your Prometheus configuration:

scrape_configs:
  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
    - targets: ['<pushgateway-host>:9091']

IMPORTANT NOTES:
1. Exporters DO NOT store historical data locally
   - They only expose current metrics state
   - Metrics are pushed to Push Gateway every ${METRICS_PUSH_INTERVAL:-30} seconds
   - Push Gateway stores metrics until Prometheus scrapes them

2. Push Gateway acts as a buffer:
   - Stores latest metrics from all instances
   - Prometheus scrapes from gateway (not exporters directly)
   - If Push Gateway restarts, metrics are lost (not on disk)

3. Data Flow:
   a) Exporters collect metrics from Redis/System
   b) push-metrics.sh reads from exporters and pushes to gateway
   c) Push Gateway stores in memory
   d) Prometheus scrapes gateway and stores in time-series DB
   e) Grafana queries Prometheus for visualization

================================================================================
VERIFICATION
================================================================================

Test push manually:
  # Single push
  ./scripts/push-metrics.sh &
  sleep 5
  pkill -f push-metrics.sh

Check Push Gateway:
  curl http://<pushgateway>:9091/metrics | grep redisforge

Check Prometheus targets:
  curl http://<prometheus>:9090/api/v1/targets

Query metrics in Prometheus:
  curl http://<prometheus>:9090/api/v1/query?query=redis_up

================================================================================
GRAFANA DASHBOARD
================================================================================

Import the pre-built Grafana dashboard from:
  monitoring/grafana/dashboards/redisforge-dashboard.json

This dashboard queries Prometheus for:
  - Redis cluster health and performance
  - System resource utilization
  - Envoy proxy metrics

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
