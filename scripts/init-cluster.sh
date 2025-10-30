#!/usr/bin/env bash
set -euo pipefail

# Initializes a Redis Cluster across three masters with replicas.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODES_CSV=${1:-}
PASSWORD=${REDIS_REQUIREPASS:-}

if [[ -z "$NODES_CSV" ]]; then
  echo "Usage: $0 'host1:6379,host2:6379,host3:6379,host4:6379,host5:6379,host6:6379'" >&2
  exit 1
fi

IFS=',' read -r -a NODES <<< "$NODES_CSV"
if (( ${#NODES[@]} < 6 )); then
  echo "Need at least 6 nodes (3 masters + 3 replicas)." >&2
  exit 1
fi

echo "Waiting for nodes to be ready..."
for node in "${NODES[@]}"; do
  until timeout 2 bash -c ">/dev/tcp/${node%:*}/${node#*:}" 2>/dev/null; do
    echo "  ${node} not ready, retrying..."; sleep 2;
  done
done

echo "Creating cluster with redis-cli..."
AUTH_ARGS=()
[[ -n "$PASSWORD" ]] && AUTH_ARGS+=(--pass "$PASSWORD")

redis-cli "${AUTH_ARGS[@]}" \
  --cluster create "${NODES[@]}" \
  --cluster-replicas 1 \
  --cluster-yes

echo "Cluster created. Checking cluster nodes:"
redis-cli "${AUTH_ARGS[@]}" -h "${NODES[0]%:*}" -p "${NODES[0]#*:}" cluster nodes | sed -n '1,20p'

