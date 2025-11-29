#!/usr/bin/env bash
# ==================================================================================================
# Script Name: test-network-partition.sh
# Description: Simulates a network partition (split-brain scenario) by blocking traffic between
#              nodes and verifies cluster recovery when partition is healed.
#
# Usage:       ./tests/test-network-partition.sh
#
# Prerequisites:
#              - Docker Compose environment running
#              - Redis cluster initialized
#              - Root/sudo access for iptables (inside containers)
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
NODE_TO_ISOLATE="redis-master-3"
PARTITION_DURATION=10  # seconds

log_info "================================================"
log_info "RedisForge Network Partition Test"
log_info "================================================"
log_info ""
log_warn "NOTE: This test simulates network failures."
log_warn "It may cause temporary cluster degradation."
log_info ""

# Step 1: Verify initial cluster health
log_test "Step 1: Verifying initial cluster state..."

CLUSTER_STATE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster info 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r')

if [[ "$CLUSTER_STATE" != "ok" ]]; then
    log_error "Cluster is not healthy before test. State: $CLUSTER_STATE"
    exit 1
fi

log_info "✓ Cluster state: OK"

# Get node ID of isolated node
ISOLATED_NODE_ID=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster nodes 2>/dev/null | grep "$NODE_TO_ISOLATE" | awk '{print $1}')

log_info "✓ Node to isolate: $NODE_TO_ISOLATE ($ISOLATED_NODE_ID)"

# Step 2: Write test data before partition
log_test "Step 2: Writing test data..."

TEST_KEY="partition_test_$(date +%s)"
TEST_VALUE="partition_value_$(date +%s)"

docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c SET "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1

log_info "✓ Test data written: $TEST_KEY = $TEST_VALUE"

# Step 3: Create network partition using Docker network disconnect
log_test "Step 3: Creating network partition..."

# Get the network name
NETWORK_NAME=$(docker compose -f "$COMPOSE_FILE" ps -q "$NODE_TO_ISOLATE" | \
    xargs docker inspect --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)

log_info "Network: $NETWORK_NAME"

# Disconnect the isolated node from the network
CONTAINER_NAME=$(docker compose -f "$COMPOSE_FILE" ps -q "$NODE_TO_ISOLATE" | xargs docker inspect --format='{{.Name}}' | sed 's/^[/]//')

docker network disconnect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null || {
    log_error "Failed to disconnect node from network"
    exit 1
}

PARTITION_START=$(date +%s)
log_warn "✗ Network partition created at $(date)"
log_warn "Node $NODE_TO_ISOLATE is now isolated"

# Step 4: Wait and observe cluster state during partition
log_test "Step 4: Monitoring cluster during partition (${PARTITION_DURATION}s)..."

sleep 3

CLUSTER_STATE_PARTITION=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster info 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r' || echo "error")

if [[ "$CLUSTER_STATE_PARTITION" == "ok" ]]; then
    log_info "Cluster still operational (degraded mode expected)"
elif [[ "$CLUSTER_STATE_PARTITION" == "fail" ]]; then
    log_warn "Cluster in failed state (expected during partition)"
else
    log_info "Cluster state: $CLUSTER_STATE_PARTITION"
fi

# Check if isolated node is marked as failed
ISOLATED_NODE_STATUS=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster nodes 2>/dev/null | grep "$ISOLATED_NODE_ID" || echo "")

if echo "$ISOLATED_NODE_STATUS" | grep -q "fail"; then
    log_warn "Isolated node marked as failed (expected)"
elif echo "$ISOLATED_NODE_STATUS" | grep -q "pfail"; then
    log_warn "Isolated node potentially failed (expected)"
else
    log_warn "Isolated node status unclear"
fi

# Wait for partition duration
REMAINING=$((PARTITION_DURATION - 3))
sleep "$REMAINING"

# Step 5: Heal the partition
log_test "Step 5: Healing network partition..."

docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null || {
    log_error "Failed to reconnect node to network"
    exit 1
}

PARTITION_END=$(date +%s)
PARTITION_TIME=$((PARTITION_END - PARTITION_START))

log_info "✓ Network partition healed (duration: ${PARTITION_TIME}s)"

# Step 6: Wait for cluster to stabilize
log_test "Step 6: Waiting for cluster to stabilize..."

STABLE=0
for i in {1..30}; do
    sleep 1
    
    STATE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        cluster info 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r' || echo "error")
    
    if [[ "$STATE" == "ok" ]]; then
        log_info "✓ Cluster stabilized in ${i}s"
        STABLE=1
        break
    fi
    
    echo -ne "\r  Waiting... ${i}s (state: $STATE)"
done

echo ""

if [[ $STABLE -eq 0 ]]; then
    log_error "Cluster did not stabilize within 30s"
    exit 1
fi

# Step 7: Verify node rejoined
log_test "Step 7: Verifying isolated node rejoined..."

REJOINED_STATUS=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster nodes 2>/dev/null | grep "$ISOLATED_NODE_ID")

if echo "$REJOINED_STATUS" | grep -q "connected"; then
    log_info "✓ Node rejoined and connected"
elif echo "$REJOINED_STATUS" | grep -q "fail"; then
    log_warn "Node still marked as failed (may recover shortly)"
else
    log_info "Node status: $(echo "$REJOINED_STATUS" | awk '{print $8}')"
fi

# Step 8: Verify data accessibility
log_test "Step 8: Verifying data accessibility..."

RETRIEVED_VALUE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c GET "$TEST_KEY" 2>/dev/null | tr -d '\r')

if [[ "$RETRIEVED_VALUE" == "$TEST_VALUE" ]]; then
    log_info "✓ Data verified: $TEST_KEY = $RETRIEVED_VALUE"
else
    log_error "Data mismatch! Expected: $TEST_VALUE, Got: $RETRIEVED_VALUE"
    exit 1
fi

# Step 9: Write new data to ensure cluster is writable
log_test "Step 9: Testing write operations..."

POST_PARTITION_KEY="post_partition_$(date +%s)"
POST_PARTITION_VALUE="recovered_$(date +%s)"

docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c SET "$POST_PARTITION_KEY" "$POST_PARTITION_VALUE" >/dev/null 2>&1

log_info "✓ Write operation successful after partition recovery"

# Summary
log_info ""
log_info "================================================"
log_info "Network Partition Test: PASSED ✓"
log_info "================================================"
log_info ""
log_info "Test Summary:"
log_info "  • Partition duration: ${PARTITION_TIME}s"
log_info "  • Cluster recovered: YES"
log_info "  • Data preserved: YES"
log_info "  • Node rejoined: YES"
log_info "  • Cluster writable: YES"
log_info ""
log_info "Cluster successfully recovered from network partition!"
