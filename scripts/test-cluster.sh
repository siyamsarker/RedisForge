#!/usr/bin/env bash
set -euo pipefail

################################################################################
# RedisForge - Cluster Integration Tests
# Simple integration tests against Envoy endpoint or Redis cluster
################################################################################

# Configuration
ENVOY_HOST=${1:-localhost}
PORT=${2:-6379}
PASS=${REDIS_REQUIREPASS:-}

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}✓${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# Check if redis-cli is installed
if ! command -v redis-cli >/dev/null 2>&1; then
  error "redis-cli is not installed. Install with: apt install redis-tools / yum install redis"
  exit 1
fi

echo "================================================"
echo "RedisForge Cluster Integration Tests"
echo "Target: ${ENVOY_HOST}:${PORT}"
echo "================================================"
echo ""

# Build auth arguments
AUTH_ARGS=()
if [[ -n "$PASS" ]]; then
  AUTH_ARGS+=(--pass "$PASS")
fi

# Trap to ensure cleanup
cleanup() {
  local exit_code=$?
  # Kill any background jobs
  jobs -p | xargs -r kill 2>/dev/null || true
  exit $exit_code
}
trap cleanup EXIT INT TERM

# Test 1: PING
echo "Test 1: PING"
if redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" ping 2>/dev/null | grep -q PONG; then
  log "PING successful"
else
  error "PING failed"
  exit 1
fi
echo ""

# Test 2: SET/GET
echo "Test 2: SET/GET"
TEST_KEY="redisforge:test:$(date +%s)"
TEST_VALUE="test-value-$(date +%s)"

if redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" set "$TEST_KEY" "$TEST_VALUE" EX 60 >/dev/null 2>&1; then
  RETRIEVED=$(redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" get "$TEST_KEY" 2>/dev/null || echo "")
  if [[ "$RETRIEVED" == "$TEST_VALUE" ]]; then
    log "SET/GET successful"
    # Cleanup test key
    redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" del "$TEST_KEY" >/dev/null 2>&1 || true
  else
    error "SET/GET failed - value mismatch (expected: $TEST_VALUE, got: $RETRIEVED)"
    exit 1
  fi
else
  error "SET command failed"
  exit 1
fi
echo ""

# Test 3: Pub/Sub (with verification)
echo "Test 3: Pub/Sub"
PUBSUB_CHANNEL="redisforge:test:pubsub:$(date +%s)"
PUBSUB_MESSAGE="test-message-$(date +%s)"
PUBSUB_OUTPUT="$(mktemp -t redisforge-pubsub.XXXXXX)"

redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" --csv subscribe "$PUBSUB_CHANNEL" > "$PUBSUB_OUTPUT" 2>/dev/null &
SUBSCRIBER_PID=$!

sleep 1

if ! redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" publish "$PUBSUB_CHANNEL" "$PUBSUB_MESSAGE" >/dev/null 2>&1; then
  kill "$SUBSCRIBER_PID" 2>/dev/null || true
  wait "$SUBSCRIBER_PID" 2>/dev/null || true
  error "Failed to publish Pub/Sub message"
  rm -f "$PUBSUB_OUTPUT" 2>/dev/null || true
  exit 1
fi

PUBSUB_SUCCESS=false
for _ in {1..10}; do
  if grep -q "$PUBSUB_MESSAGE" "$PUBSUB_OUTPUT" 2>/dev/null; then
    PUBSUB_SUCCESS=true
    break
  fi
  sleep 0.5
done

kill "$SUBSCRIBER_PID" 2>/dev/null || true
wait "$SUBSCRIBER_PID" 2>/dev/null || true

if $PUBSUB_SUCCESS; then
  log "Pub/Sub successful"
else
  error "Pub/Sub message was not received on channel ${PUBSUB_CHANNEL}"
  rm -f "$PUBSUB_OUTPUT" 2>/dev/null || true
  exit 1
fi

rm -f "$PUBSUB_OUTPUT" 2>/dev/null || true
echo ""

# Test 4: Cluster Info
echo "Test 4: Cluster Information"
if CLUSTER_INFO=$(redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" cluster info 2>/dev/null); then
  if echo "$CLUSTER_INFO" | grep -q "cluster_state:ok"; then
    log "Cluster state: OK"
  elif echo "$CLUSTER_INFO" | grep -q "cluster_state:fail"; then
    error "Cluster state: FAIL"
    echo "$CLUSTER_INFO" | head -10
    exit 1
  else
    log "Cluster info retrieved (non-cluster or unavailable)"
  fi
else
  log "Not a Redis cluster (standalone mode or cluster not configured)"
fi
echo ""

# Test 5: Server Info
echo "Test 5: Server Information"
if INFO=$(redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" info server 2>/dev/null); then
  REDIS_VERSION=$(echo "$INFO" | grep "^redis_version:" | cut -d: -f2 | tr -d '\r')
  UPTIME=$(echo "$INFO" | grep "^uptime_in_seconds:" | cut -d: -f2 | tr -d '\r')
  
  log "Redis version: $REDIS_VERSION"
  log "Uptime: ${UPTIME}s"
else
  error "Failed to retrieve server info"
  exit 1
fi
echo ""

# Summary
echo "================================================"
echo "✓ All tests passed successfully!"
echo "================================================"

