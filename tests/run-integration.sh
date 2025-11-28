#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="tests/docker-compose.integration.yml"
REDIS_PASS="DevPassw0rd!"
CERT_DIR="config/tls/dev"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT

./scripts/generate-certs.sh "$CERT_DIR"

cleanup

docker compose -f "$COMPOSE_FILE" build --pull

docker compose -f "$COMPOSE_FILE" up -d

echo "Waiting for Redis nodes to accept connections..."
for host in redis-master-1 redis-master-2 redis-master-3 redis-replica-1 redis-replica-2 redis-replica-3; do
  until docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "redis-cli -h $host -p 6379 -a '$REDIS_PASS' PING" >/dev/null 2>&1; do
    sleep 1
  done
done

echo "Waiting for bash installation in toolbox..."
until docker compose -f "$COMPOSE_FILE" exec -T toolbox bash -c "echo bash ready" >/dev/null 2>&1; do
  sleep 1
done

echo "Initializing cluster..."
NODES="redis-master-1:6379,redis-master-2:6379,redis-master-3:6379,redis-replica-1:6379,redis-replica-2:6379,redis-replica-3:6379"
docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' ./scripts/init-cluster.sh '$NODES'"

echo "Running integration tests via Envoy..."
docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' TLS_ENABLED=true TLS_CA_FILE=/workspace/$CERT_DIR/ca.crt TLS_SERVER_NAME=redisforge.local ./scripts/test-cluster.sh envoy 6379"

echo "Testing scaling: Adding a new replica (redis-spare-1)..."
# Get Master 1 ID
MASTER_ID=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "redis-cli -h redis-master-1 -p 6379 -a '$REDIS_PASS' cluster myid" | tr -d '\r')
docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' ./scripts/scale.sh add redis-spare-1:6379 --role replica --replica-of $MASTER_ID"

echo "Testing scaling: Removing the new replica..."
# Get Spare Node ID
SPARE_ID=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "redis-cli -h redis-spare-1 -p 6379 -a '$REDIS_PASS' cluster myid" | tr -d '\r')
docker compose -f "$COMPOSE_FILE" exec -T toolbox sh -c "cd /workspace && REDIS_REQUIREPASS='$REDIS_PASS' ./scripts/scale.sh remove $SPARE_ID"

echo "All integration tests passed."
