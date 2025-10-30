#!/usr/bin/env bash
set -euo pipefail

################################################################################
# RedisForge - Cluster Scaling Script
# Add or remove nodes and rebalance/reshard with minimal disruption
################################################################################

# Usage information
usage() {
  cat << EOF
Usage:
  Add node:    $0 add <host:port> [SEED=<seed_host:port>]
  Remove node: $0 remove <node_id> [SEED=<seed_host:port>]

Environment Variables:
  REDIS_REQUIREPASS - Redis authentication password
  SEED              - Existing cluster node (auto-detected if not provided)
  CLUSTER_SEED      - Fallback seed node
  CLUSTER_NODES     - Comma-separated list of cluster nodes

Examples:
  $0 add 10.0.1.15:6379
  $0 remove a1b2c3d4e5f6g7h8
  SEED=10.0.1.10:6379 $0 add 10.0.1.15:6379
EOF
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"; }

# Check if redis-cli is installed
if ! command -v redis-cli >/dev/null 2>&1; then
  error "redis-cli not found. Install with: apt install redis-tools / yum install redis"
  exit 1
fi

# Parse arguments
ACTION=${1:-}
ARG=${2:-}

if [[ -z "$ACTION" ]] || [[ -z "$ARG" ]]; then
  usage
  exit 1
fi

# Build auth arguments
AUTH_ARGS=()
if [[ -n "${REDIS_REQUIREPASS:-}" ]]; then
  AUTH_ARGS+=(--pass "$REDIS_REQUIREPASS")
fi

# Determine seed node
SEED=${SEED:-}
if [[ -z "$SEED" ]]; then
  if [[ -n "${CLUSTER_SEED:-}" ]]; then
    SEED="$CLUSTER_SEED"
  elif [[ -n "${CLUSTER_NODES:-}" ]]; then
    IFS=',' read -r -a __ARR <<< "${CLUSTER_NODES}"
    SEED="${__ARR[0]}"
  else
    SEED="127.0.0.1:${REDIS_PORT:-6379}"
  fi
fi

# Validate seed node
HOST=${SEED%:*}
PORT=${SEED#*:}

if [[ -z "$HOST" ]] || [[ -z "$PORT" ]] || ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  error "Invalid seed node format: $SEED (expected: host:port)"
  exit 1
fi

log "Using seed node: $SEED"

# Check seed node connectivity
if ! timeout 5 bash -c ">/dev/tcp/$HOST/$PORT" 2>/dev/null; then
  error "Cannot connect to seed node: $SEED"
  exit 1
fi

if ! redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" ping 2>/dev/null | grep -q PONG; then
  error "Seed node $SEED is not responding to PING"
  exit 1
fi

log "Seed node is online"

# Handle actions
case "$ACTION" in
  add)
    NEW_NODE="$ARG"
    NEW_HOST=${NEW_NODE%:*}
    NEW_PORT=${NEW_NODE#*:}
    
    # Validate new node format
    if [[ -z "$NEW_HOST" ]] || [[ -z "$NEW_PORT" ]] || ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
      error "Invalid node format: $NEW_NODE (expected: host:port)"
      exit 1
    fi
    
    log "Adding new node: $NEW_NODE"
    
    # Check if new node is reachable
    if ! timeout 5 bash -c ">/dev/tcp/$NEW_HOST/$NEW_PORT" 2>/dev/null; then
      error "Cannot connect to new node: $NEW_NODE"
      exit 1
    fi
    
    # Check if new node is empty
    if ! redis-cli -h "$NEW_HOST" -p "$NEW_PORT" "${AUTH_ARGS[@]}" ping 2>/dev/null | grep -q PONG; then
      error "New node $NEW_NODE is not responding"
      exit 1
    fi
    
    log "New node is online and ready"
    
    # Add node as replica
    log "Adding node as replica..."
    if ! redis-cli "${AUTH_ARGS[@]}" --cluster add-node "$NEW_NODE" "$SEED" --cluster-slave; then
      error "Failed to add node $NEW_NODE"
      exit 1
    fi
    
    log "✓ Node added as replica"
    
    # Rebalance cluster
    log "Rebalancing cluster to distribute slots..."
    if ! redis-cli "${AUTH_ARGS[@]}" --cluster rebalance "$SEED" --cluster-threshold 1.05 --cluster-yes; then
      warn "Rebalancing failed or not needed"
    else
      log "✓ Cluster rebalanced"
    fi
    
    log "✓ Node $NEW_NODE successfully added to cluster"
    ;;
    
  remove)
    NODE_ID="$ARG"
    
    # Validate node ID format (40-character hex string)
    if ! [[ "$NODE_ID" =~ ^[a-f0-9]{40}$ ]]; then
      error "Invalid node ID format: $NODE_ID (expected: 40-character hex string)"
      error "Get node IDs with: redis-cli -h $HOST -p $PORT cluster nodes"
      exit 1
    fi
    
    log "Removing node: $NODE_ID"
    
    # Check if node exists in cluster
    if ! redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster nodes | grep -q "^$NODE_ID"; then
      error "Node ID $NODE_ID not found in cluster"
      error "Available nodes:"
      redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster nodes | awk '{print $1, $2, $3}'
      exit 1
    fi
    
    # Rebalance to drain slots from target node
    log "Draining slots from node $NODE_ID..."
    log "This may take several minutes for large datasets..."
    
    if ! redis-cli "${AUTH_ARGS[@]}" --cluster rebalance "$SEED" \
         --cluster-weight "$NODE_ID"=0 \
         --cluster-use-empty-masters \
         --cluster-threshold 1.05 \
         --cluster-yes; then
      warn "Slot draining failed or not needed (node may be a replica)"
    else
      log "✓ Slots drained from node"
    fi
    
    # Remove node from cluster
    log "Removing node from cluster..."
    if ! redis-cli "${AUTH_ARGS[@]}" --cluster del-node "$SEED" "$NODE_ID"; then
      error "Failed to remove node $NODE_ID"
      exit 1
    fi
    
    log "✓ Node $NODE_ID successfully removed from cluster"
    ;;
    
  *)
    error "Unknown action: $ACTION"
    usage
    exit 1
    ;;
esac

# Verify cluster health
log "Verifying cluster health..."
if CLUSTER_INFO=$(redis-cli -h "$HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster info 2>/dev/null); then
  if echo "$CLUSTER_INFO" | grep -q "cluster_state:ok"; then
    log "✓ Cluster state: OK"
  else
    warn "Cluster state may not be optimal:"
    echo "$CLUSTER_INFO"
  fi
else
  warn "Could not verify cluster state"
fi

log "================================================"
log "✓ Scaling operation complete!"
log "================================================"

