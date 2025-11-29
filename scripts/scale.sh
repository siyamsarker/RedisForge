#!/usr/bin/env bash
# ==================================================================================================
# Script Name: scale.sh
# Description: Manages Redis Cluster scaling operations.
#              - Adds new master or replica nodes
#              - Removes existing nodes
#              - Handles cluster rebalancing and slot migration
#              - Ensures zero-downtime scaling
#
# Usage:       ./scripts/scale.sh [ACTION] [TARGET] [OPTIONS]
#
# Actions:
#   add <host:port>     - Add a new node to the cluster
#   remove <node_id>    - Remove a node from the cluster
#
# Options:
#   --role [master|replica]        - Role for new node (default: master)
#   --replica-of <master_id>       - Master ID to replicate (required for replica)
#
# Environment Variables:
#   REDIS_REQUIREPASS - Redis authentication password
#   SEED              - Existing cluster node to connect to (auto-detected)
#
# Author:      RedisForge Team
# License:     MIT
# ==================================================================================================

set -euo pipefail

# Usage information
usage() {
  cat << EOF
Usage:
  Add master:  $0 add <host:port> [--role master] [SEED=<seed_host:port>]
  Add replica: $0 add <host:port> --role replica --replica-of <master_node_id>
  Remove:      $0 remove <node_id> [SEED=<seed_host:port>]

Environment Variables:
  REDIS_REQUIREPASS - Redis authentication password
  SEED              - Existing cluster node (auto-detected if not provided)
  CLUSTER_SEED      - Fallback seed node
  CLUSTER_NODES     - Comma-separated list of cluster nodes

Examples:
  $0 add 10.0.1.15:6379 --role master
  $0 add 10.0.1.16:6379 --role replica --replica-of e1f2a3...
  $0 remove a1b2c3d4e5f6g7h8
  SEED=10.0.1.10:6379 $0 add 10.0.1.17:6379 --role master
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
shift || true

if [[ -z "$ACTION" ]]; then
  usage
  exit 1
fi

ROLE="master"
REPLICA_OF=""
TARGET=""

case "$ACTION" in
  add)
    TARGET=${1:-}
    if [[ -z "$TARGET" ]]; then
      usage
      exit 1
    fi
    shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --role)
          ROLE="${2:-}"
          shift 2 || { usage; exit 1; }
          ;;
        --replica-of)
          REPLICA_OF="${2:-}"
          shift 2 || { usage; exit 1; }
          ;;
        *)
          error "Unknown option: $1"
          usage
          exit 1
          ;;
      esac
    done
    ;;
  remove)
    TARGET=${1:-}
    if [[ -z "$TARGET" ]]; then
      usage
      exit 1
    fi
    ;;
  *)
    error "Unknown action: $ACTION"
    usage
    exit 1
    ;;
esac

if [[ "$ACTION" == "add" ]]; then
  if [[ "$ROLE" != "master" && "$ROLE" != "replica" ]]; then
    error "Invalid role: $ROLE (expected master or replica)"
    exit 1
  fi
  if [[ "$ROLE" == "replica" && -z "$REPLICA_OF" ]]; then
    error "Replica addition requires --replica-of <master_node_id>"
    exit 1
  fi
fi

# Build auth arguments
AUTH_ARGS=()
if [[ -n "${REDIS_REQUIREPASS:-}" ]]; then
  AUTH_ARGS+=(--pass "$REDIS_REQUIREPASS")
fi

# ==================================================================================================
# Seed Node Discovery
# ==================================================================================================
# Determines which existing cluster node to use as an entry point (seed).
# Priority:
# 1. SEED env var
# 2. CLUSTER_SEED env var
# 3. First node from CLUSTER_NODES list
# 4. Default to localhost:6379

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
    NEW_NODE="$TARGET"
    NEW_HOST=${NEW_NODE%:*}
    NEW_PORT=${NEW_NODE#*:}
    
    # Validate new node format
    if [[ -z "$NEW_HOST" ]] || [[ -z "$NEW_PORT" ]] || ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
      error "Invalid node format: $NEW_NODE (expected: host:port)"
      exit 1
    fi
    
    log "Adding new $ROLE node: $NEW_NODE"
    
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
    
    if [[ "$ROLE" == "master" ]]; then
      log "Adding node as master..."
      # Add node to cluster
      if ! redis-cli "${AUTH_ARGS[@]}" --cluster add-node "$NEW_NODE" "$SEED"; then
        error "Failed to add node $NEW_NODE as master"
        exit 1
      fi
      
      log "✓ Node added as master"
      log "Rebalancing cluster to distribute slots..."
      
      # Rebalance cluster to assign slots to the new master
      # --cluster-threshold 1.05: Only rebalance if imbalance > 5%
      if ! redis-cli "${AUTH_ARGS[@]}" --cluster rebalance "$SEED" --cluster-threshold 1.05 --cluster-yes; then
        warn "Rebalancing failed or not needed"
      else
        log "✓ Cluster rebalanced"
      fi
    else
      log "Adding node as replica of $REPLICA_OF..."
      if ! [[ "$REPLICA_OF" =~ ^[a-f0-9]{40}$ ]]; then
        error "Invalid master node ID for replica: $REPLICA_OF"
        exit 1
      fi
      if ! redis-cli "${AUTH_ARGS[@]}" --cluster add-node "$NEW_NODE" "$SEED" --cluster-slave --cluster-master-id "$REPLICA_OF"; then
        error "Failed to add node $NEW_NODE as replica"
        exit 1
      fi
      log "✓ Node added as replica"
    fi
    
    log "✓ Node $NEW_NODE successfully added to cluster"
    ;;
    
  remove)
    NODE_ID="$TARGET"
    
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
    # Moves all slots from the target node to other masters.
    # --cluster-weight <node_id>=0: Tells Redis to assign 0 weight (0 slots) to this node.
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

