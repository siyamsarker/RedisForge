#!/usr/bin/env bash
set -euo pipefail

# Add or remove nodes and rebalance/reshard with minimal disruption.
# Usage:
#   Add:    ./scripts/scale.sh add host:port [SEED=host:port]
#   Remove: ./scripts/scale.sh remove node_id   [SEED=host:port]

ACTION=${1:-}
ARG=${2:-}

AUTH_ARGS=()
[[ -n "${REDIS_REQUIREPASS:-}" ]] && AUTH_ARGS+=(--pass "$REDIS_REQUIREPASS")

# Choose a seed node in the existing cluster
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

if [[ "$ACTION" == "add" ]]; then
  if [[ -z "$ARG" ]]; then echo "Provide host:port"; exit 1; fi
  echo "Adding node $ARG as a replica (auto-rebalance after)..."
  redis-cli "${AUTH_ARGS[@]}" --cluster add-node "$ARG" "$SEED" --cluster-slave
  echo "Rebalancing slots to include $ARG ..."
  redis-cli "${AUTH_ARGS[@]}" --cluster rebalance "$SEED" --cluster-threshold 1.05 --cluster-yes
elif [[ "$ACTION" == "remove" ]]; then
  if [[ -z "$ARG" ]]; then echo "Provide node_id"; exit 1; fi
  echo "Rebalancing cluster to drain slots from $ARG ..."
  # Set weight of target node to 0 so rebalancer evacuates its slots
  redis-cli "${AUTH_ARGS[@]}" --cluster rebalance "$SEED" --cluster-weight "$ARG"=0 --cluster-use-empty-masters --cluster-threshold 1.05 --cluster-yes || true
  echo "Removing node $ARG ..."
  redis-cli "${AUTH_ARGS[@]}" --cluster del-node "$SEED" "$ARG"
else
  echo "Usage: $0 [add host:port | remove node_id]"; exit 1
fi

