#!/usr/bin/env bash
set -euo pipefail

################################################################################
# RedisForge - Redis Cluster Initialization Script
# Initializes a Redis Cluster across multiple masters with replicas
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
NODES_CSV=${1:-}
PASSWORD=${REDIS_REQUIREPASS:-}
MAX_RETRIES=${MAX_RETRIES:-30}
RETRY_DELAY=${RETRY_DELAY:-2}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"; }

# Validate inputs
if [[ -z "$NODES_CSV" ]]; then
  error "Usage: $0 'host1:6379,host2:6379,host3:6379,host4:6379,host5:6379,host6:6379'"
  error "Provide comma-separated list of at least 6 nodes (3 masters + 3 replicas)"
  exit 1
fi

# Check if redis-cli is installed
if ! command -v redis-cli >/dev/null 2>&1; then
  error "redis-cli not found. Install with: apt install redis-tools / yum install redis"
  exit 1
fi

# Parse nodes
IFS=',' read -r -a NODES <<< "$NODES_CSV"

if (( ${#NODES[@]} < 6 )); then
  error "Need at least 6 nodes (3 masters + 3 replicas). Provided: ${#NODES[@]}"
  exit 1
fi

log "================================================"
log "RedisForge Cluster Initialization"
log "Nodes: ${#NODES[@]}"
log "================================================"
echo ""

# Build auth arguments
AUTH_ARGS=()
if [[ -n "$PASSWORD" ]]; then
  AUTH_ARGS+=(--pass "$PASSWORD")
fi

# Wait for all nodes to be ready
log "Checking node connectivity..."
for node in "${NODES[@]}"; do
  HOST=${node%:*}
  PORT=${node#*:}
  
  # Validate format
  if [[ -z "$HOST" ]] || [[ -z "$PORT" ]] || ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    error "Invalid node format: $node (expected: host:port)"
    exit 1
  fi
  
  log "Checking $node..."
  retries=0
  
  while (( retries < MAX_RETRIES )); do
    if timeout 5 bash -c ">/dev/tcp/$HOST/$PORT" 2>/dev/null; then
      # Try PING command
      if redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" ping 2>/dev/null | grep -q PONG; then
        log "  ✓ $node is ready"
        break
      fi
    fi
    
    retries=$((retries + 1))
    if (( retries >= MAX_RETRIES )); then
      error "  ✗ $node not ready after $MAX_RETRIES attempts"
      exit 1
    fi
    
    warn "  → $node not ready, retrying ($retries/$MAX_RETRIES)..."
    sleep "$RETRY_DELAY"
  done
done

echo ""
log "All nodes are ready. Creating cluster..."

# Create cluster
log "Executing redis-cli --cluster create..."
if redis-cli "${AUTH_ARGS[@]}" \
  --cluster create "${NODES[@]}" \
  --cluster-replicas 1 \
  --cluster-yes; then
  log "✓ Cluster created successfully!"
else
  error "✗ Cluster creation failed"
  exit 1
fi

echo ""
log "Verifying cluster status..."

# Verify cluster
FIRST_NODE=${NODES[0]}
HOST=${FIRST_NODE%:*}
PORT=${FIRST_NODE#*:}

# Check cluster info
if ! CLUSTER_INFO=$(redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster info 2>/dev/null); then
  error "Failed to retrieve cluster info"
  exit 1
fi

if echo "$CLUSTER_INFO" | grep -q "cluster_state:ok"; then
  log "✓ Cluster state: OK"
else
  error "✗ Cluster state is not OK:"
  echo "$CLUSTER_INFO"
  exit 1
fi

# Display cluster nodes
echo ""
log "Cluster nodes:"
echo "================================================"
redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster nodes | head -20
echo "================================================"
echo ""

# Display cluster slots
log "Checking slot distribution..."
if SLOTS=$(redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster slots 2>/dev/null); then
  MASTER_COUNT=$(echo "$SLOTS" | grep -c "^[0-9]" || echo 0)
  log "✓ Slots distributed across $MASTER_COUNT masters"
else
  warn "Could not verify slot distribution"
fi

echo ""
log "================================================"
log "✓ Cluster initialization complete!"
log "================================================"
log "Next steps:"
log "  1. Test connectivity: redis-cli -h $HOST -p $PORT -a \$PASSWORD cluster info"
log "  2. Run tests: ./scripts/test-cluster.sh $HOST $PORT"
log "  3. Deploy Envoy proxy: ./scripts/deploy.sh envoy"

