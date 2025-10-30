#!/usr/bin/env bash

################################################################################
# RedisForge - Push Metrics to Prometheus Push Gateway
# Continuously pushes metrics from exporters to Prometheus
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  source "${REPO_ROOT}/.env"
  set +a
fi

# Configuration
PUSHGATEWAY="${PROMETHEUS_PUSHGATEWAY:-}"
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"
JOB_PREFIX="${JOB_PREFIX:-redisforge}"
PUSH_INTERVAL="${METRICS_PUSH_INTERVAL:-30}"

if [[ -z "$PUSHGATEWAY" ]]; then
  echo "Error: PROMETHEUS_PUSHGATEWAY not set in .env"
  echo "Example: PROMETHEUS_PUSHGATEWAY=http://pushgateway.example.com:9091"
  exit 1
fi

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"; }

# Function to push metrics
push_metrics() {
  local job_name="$1"
  local port="$2"
  local endpoint="${3:-/metrics}"
  
  if ! curl -sf "http://localhost:${port}${endpoint}" | \
     curl -sf --data-binary @- "${PUSHGATEWAY}/metrics/job/${JOB_PREFIX}_${job_name}/instance/${INSTANCE_NAME}"; then
    error "Failed to push ${job_name} metrics"
    return 1
  fi
  
  log "✓ ${job_name} metrics pushed"
  return 0
}

# Main push loop
main() {
  log "================================================"
  log "Starting metrics push service"
  log "Gateway: ${PUSHGATEWAY}"
  log "Instance: ${INSTANCE_NAME}"
  log "Push Interval: ${PUSH_INTERVAL}s"
  log "================================================"
  echo ""

  while true; do
    local push_success=true
    
    # Push Redis Exporter metrics
    if docker ps | grep -q redis-exporter; then
      push_metrics "redis" "${REDIS_EXPORTER_PORT:-9121}" "/metrics" || push_success=false
    else
      warn "redis-exporter not running"
    fi

    # Push Node Exporter metrics
    if docker ps | grep -q node-exporter; then
      push_metrics "node" "${NODE_EXPORTER_PORT:-9100}" "/metrics" || push_success=false
    else
      warn "node-exporter not running"
    fi

    # Push Envoy metrics (if on Envoy host)
    if docker ps | grep -q envoy-proxy; then
      push_metrics "envoy" "${ENVOY_ADMIN_PORT:-9901}" "/stats/prometheus" || push_success=false
    fi

    if $push_success; then
      log "All metrics pushed successfully"
    else
      error "Some metrics failed to push"
    fi
    
    echo ""
    log "Next push in ${PUSH_INTERVAL}s..."
    sleep "${PUSH_INTERVAL}"
  done
}

main "$@"
