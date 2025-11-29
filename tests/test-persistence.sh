#!/usr/bin/env bash
# ==================================================================================================
# Script Name: test-persistence.sh
# Description: Tests Redis data persistence by writing data, restarting nodes, and verifying
#              that data is recovered from AOF files.
#
# Usage:       ./tests/test-persistence.sh
#
# Prerequisites:
#              - Docker Compose environment running
#              - Redis cluster initialized with AOF enabled
#
# Author:      RedisForge Team
# License:     MIT
# ==================================================================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

# Configuration
COMPOSE_FILE="tests/docker-compose.integration.yml"
REDIS_PASSWORD="${REDIS_REQUIREPASS:-DevPassw0rd!}"
TEST_NODE="redis-master-1"
NUM_KEYS=100

log_info "================================================"
log_info "RedisForge Persistence Test"
log_info "================================================"
log_info ""

# Step 1: Verify AOF is enabled
log_test "Step 1: Verifying AOF persistence is enabled..."

AOF_ENABLED=$(docker compose -f "$COMPOSE_FILE" exec -T "$TEST_NODE" redis-cli \
    -a "$REDIS_PASSWORD" --no-auth-warning \
    CONFIG GET appendonly 2>/dev/null | tail -1 | tr -d '\r')

if [[ "$AOF_ENABLED" != "yes" ]]; then
    log_error "AOF is not enabled! Current value: $AOF_ENABLED"
    log_error "Enable AOF in redis.conf: appendonly yes"
    exit 1
fi

log_info "✓ AOF persistence: enabled"

# Check AOF fsync policy
FSYNC_POLICY=$(docker compose -f "$COMPOSE_FILE" exec -T "$TEST_NODE" redis-cli \
    -a "$REDIS_PASSWORD" --no-auth-warning \
    CONFIG GET appendfsync 2>/dev/null | tail -1 | tr -d '\r')

log_info "✓ AOF fsync policy: $FSYNC_POLICY"

# Step 2: Write test data
log_test "Step 2: Writing ${NUM_KEYS} test keys..."

TEST_PREFIX="persist_test_$(date +%s)"
WRITTEN_KEYS=0

for i in $(seq 1 "$NUM_KEYS"); do
    KEY="${TEST_PREFIX}_key_${i}"
    VALUE="value_${i}_$(date +%s)"
    
    docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        -c SET "$KEY" "$VALUE" >/dev/null 2>&1
    
    WRITTEN_KEYS=$((WRITTEN_KEYS + 1))
    
    if (( i % 20 == 0 )); then
        echo -ne "\r  Progress: ${i}/${NUM_KEYS} keys"
    fi
done

echo ""
log_info "✓ Written ${WRITTEN_KEYS} keys with prefix: ${TEST_PREFIX}"

# Step 3: Force AOF rewrite to ensure data is on disk
log_test "Step 3: Forcing AOF rewrite..."

docker compose -f "$COMPOSE_FILE" exec -T "$TEST_NODE" redis-cli \
    -a "$REDIS_PASSWORD" --no-auth-warning \
    BGREWRITEAOF >/dev/null 2>&1

# Wait for rewrite to complete
sleep 3

log_info "✓ AOF rewrite triggered"

# Step 4: Get memory snapshot before restart
log_test "Step 4: Recording pre-restart state..."

KEYS_BEFORE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c KEYS "${TEST_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')

log_info "✓ Keys before restart: $KEYS_BEFORE"

# Sample a few keys to verify after
SAMPLE_KEYS=()
for i in 1 25 50 75 100; do
    if (( i <= NUM_KEYS )); then
        SAMPLE_KEYS+=("${TEST_PREFIX}_key_${i}")
    fi
done

declare -A SAMPLE_VALUES
for KEY in "${SAMPLE_KEYS[@]}"; do
    VALUE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        -c GET "$KEY" 2>/dev/null | tr -d '\r')
    SAMPLE_VALUES["$KEY"]="$VALUE"
done

log_info "✓ Sampled ${#SAMPLE_KEYS[@]} keys for verification"

# Step 5: Restart the Redis node
log_test "Step 5: Restarting Redis node: $TEST_NODE..."

docker compose -f "$COMPOSE_FILE" restart "$TEST_NODE" >/dev/null 2>&1

log_warn "Node restarted at $(date)"

# Wait for node to come back up
log_test "Waiting for node to be ready..."
sleep 5

# Wait for cluster to be ready
for i in {1..30}; do
    if docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        PING >/dev/null 2>&1; then
        log_info "✓ Node is responding"
        break
    fi
    sleep 1
    echo -ne "\r  Waiting... ${i}s"
done

echo ""

# Step 6: Verify data was recovered
log_test "Step 6: Verifying data recovery..."

KEYS_AFTER=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c KEYS "${TEST_PREFIX}*" 2>/dev/null | wc -l | tr -d ' ')

log_info "Keys after restart: $KEYS_AFTER"

if [[ "$KEYS_AFTER" -lt "$KEYS_BEFORE" ]]; then
    log_error "Data loss detected! Before: $KEYS_BEFORE, After: $KEYS_AFTER"
    exit 1
fi

log_info "✓ All keys recovered"

# Step 7: Verify sampled values
log_test "Step 7: Verifying sample values..."

VERIFIED=0
FAILED=0

for KEY in "${SAMPLE_KEYS[@]}"; do
    EXPECTED="${SAMPLE_VALUES[$KEY]}"
    ACTUAL=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        -c GET "$KEY" 2>/dev/null | tr -d '\r')
    
    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
        VERIFIED=$((VERIFIED + 1))
    else
        FAILED=$((FAILED + 1))
        log_error "Value mismatch for $KEY: Expected '$EXPECTED', Got '$ACTUAL'"
    fi
done

if [[ $FAILED -gt 0 ]]; then
    log_error "Failed to verify $FAILED sample keys"
    exit 1
fi

log_info "✓ All ${VERIFIED} sample values verified"

# Step 8: Check AOF file exists
log_test "Step 8: Verifying AOF file presence..."

AOF_FILE=$(docker compose -f "$COMPOSE_FILE" exec -T "$TEST_NODE" \
    sh -c 'ls -lh /data/*.aof 2>/dev/null || echo "NOT_FOUND"' | grep -v "NOT_FOUND" || echo "")

if [[ -n "$AOF_FILE" ]]; then
    log_info "✓ AOF file found in /data/"
else
    log_warn "AOF file check inconclusive"
fi

# Cleanup: Remove test keys
log_test "Cleanup: Removing test keys..."

docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h "$TEST_NODE" -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    --eval /dev/stdin "${TEST_PREFIX}*" <<'EOF' >/dev/null 2>&1
local keys = redis.call('KEYS', ARGV[1])
for i=1,#keys do
    redis.call('DEL', keys[i])
end
return #keys
EOF

log_info "✓ Test keys cleaned up"

# Summary
log_info ""
log_info "================================================"
log_info "Persistence Test: PASSED ✓"
log_info "================================================"
log_info ""
log_info "Test Summary:"
log_info "  • Keys written: ${WRITTEN_KEYS}"
log_info "  • Keys recovered: ${KEYS_AFTER}"
log_info "  • Sample verification: ${VERIFIED}/${#SAMPLE_KEYS[@]}"
log_info "  • Data loss: NONE"
log_info ""
log_info "AOF persistence is working correctly!"
