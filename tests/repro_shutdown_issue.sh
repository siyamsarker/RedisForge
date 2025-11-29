#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="tests/docker-compose.integration.yml"
REDIS_PASS="DevPassw0rd!"
CERT_DIR="config/tls/dev"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT

# 1. Setup
./scripts/generate-certs.sh "$CERT_DIR"
cleanup
docker compose -f "$COMPOSE_FILE" build --pull
docker compose -f "$COMPOSE_FILE" up -d

echo "Waiting for Redis nodes..."
for host in redis-master-1 redis-master-2 redis-master-3 redis-replica-1 redis-replica-2 redis-replica-3; do
  until docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "redis-cli -h $host -p 6379 -a '$REDIS_PASS' PING" >/dev/null 2>&1; do
    sleep 1
  done
done

# 2. Initialize Cluster
echo "Initializing cluster..."
NODES="redis-master-1:6379,redis-master-2:6379,redis-master-3:6379,redis-replica-1:6379,redis-replica-2:6379,redis-replica-3:6379"
docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' ./scripts/init-cluster.sh '$NODES'"

# 3. Attempt to remove a replica
echo "Attempting to remove a replica..."
# Get a replica ID
REPLICA_ID=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "redis-cli -h redis-master-1 -p 6379 -a '$REDIS_PASS' cluster nodes | grep 'slave\|replica' | head -n 1 | awk '{print \$1}'" | tr -d '\r')

echo "Removing replica node ID: $REPLICA_ID"

if docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' ./scripts/scale.sh remove '$REPLICA_ID'"; then
  echo "SUCCESS: Node removed successfully (Unexpected if SHUTDOWN is renamed)"
else
  echo "FAILURE: Node removal failed (Expected if SHUTDOWN is renamed)"
  # Check logs to see why
  echo "Checking redis-master-1 logs..."
  docker compose -f "$COMPOSE_FILE" logs redis-master-1 | tail -n 20
fi
