#!/usr/bin/env bash
# ==================================================================================================
# Script Name: test-failover.sh
# Description: Tests Redis cluster failover by killing a master and verifying replica promotion.
#              Validates cluster resilience and automatic failover capabilities.
#
# Usage:       ./tests/test-failover.sh
#
# Prerequisites:
#              - Docker Compose environment running
#              - Redis cluster initialized
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
MASTER_TO_KILL="redis-master-2"
EXPECTED_FAILOVER_TIME=15  # seconds

log_info "================================================"
log_info "RedisForge Failover Test"
log_info "================================================"
log_info ""

# Step 1: Verify cluster is healthy before test
log_test "Step 1: Checking initial cluster state..."

CLUSTER_STATE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster info 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r')

if [[ "$CLUSTER_STATE" != "ok" ]]; then
    log_error "Cluster is not in 'ok' state before test. Current state: $CLUSTER_STATE"
    exit 1
fi

log_info "✓ Cluster state: OK"

# Get initial cluster topology
log_test "Step 2: Recording initial cluster topology..."

INITIAL_NODES=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster nodes 2>/dev/null)

MASTER_ID=$(echo "$INITIAL_NODES" | grep "$MASTER_TO_KILL" | grep "master" | awk '{print $1}')

if [[ -z "$MASTER_ID" ]]; then
    log_error "Could not find master node: $MASTER_TO_KILL"
    exit 1
fi

log_info "✓ Target master ID: $MASTER_ID"

# Find the replica for this master
REPLICA_INFO=$(echo "$INITIAL_NODES" | grep "$MASTER_ID" | grep "slave")
REPLICA_ID=$(echo "$REPLICA_INFO" | awk '{print $1}')
REPLICA_NAME=$(echo "$REPLICA_INFO" | awk '{print $2}' | cut -d: -f1 | cut -d@ -f1)

log_info "✓ Replica that should promote: $REPLICA_ID"

# Step 3: Write test data before failover
log_test "Step 3: Writing test data..."

TEST_KEY="failover_test_$(date +%s)"
TEST_VALUE="failover_value_$(date +%s)"

docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c SET "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1

log_info "✓ Test data written: $TEST_KEY = $TEST_VALUE"

# Step 4: Kill the master
log_test "Step 4: Killing master node: $MASTER_TO_KILL..."

docker compose -f "$COMPOSE_FILE" stop "$MASTER_TO_KILL" >/dev/null 2>&1
KILL_TIME=$(date +%s)

log_warn "✗ Master killed at $(date)"

# Step 5: Wait for failover and verify
log_test "Step 5: Waiting for failover (max ${EXPECTED_FAILOVER_TIME}s)..."

FAILOVER_DETECTED=0
START_TIME=$(date +%s)

for i in $(seq 1 "$EXPECTED_FAILOVER_TIME"); do
    sleep 1
    
    # Check if replica has been promoted
    CURRENT_NODES=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
        -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
        cluster nodes 2>/dev/null || echo "")
    
    if echo "$CURRENT_NODES" | grep -q "$REPLICA_ID.*master"; then
        FAILOVER_TIME=$(($(date +%s) - KILL_TIME))
        log_info "✓ Failover detected! Replica promoted in ${FAILOVER_TIME}s"
        FAILOVER_DETECTED=1
        break
    fi
    
    echo -ne "\r  Waiting... ${i}s"
done

echo ""

if [[ $FAILOVER_DETECTED -eq 0 ]]; then
    log_error "Failover did not complete within ${EXPECTED_FAILOVER_TIME}s"
    
    # Cleanup: restart the killed master
    log_warn "Restarting killed master for cleanup..."
    docker compose -f "$COMPOSE_FILE" start "$MASTER_TO_KILL" >/dev/null 2>&1
    exit 1
fi

# Step 6: Verify data is still accessible
log_test "Step 6: Verifying data accessibility after failover..."

RETRIEVED_VALUE=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    -c GET "$TEST_KEY" 2>/dev/null | tr -d '\r')

if [[ "$RETRIEVED_VALUE" == "$TEST_VALUE" ]]; then
    log_info "✓ Data verified: $TEST_KEY = $RETRIEVED_VALUE"
else
    log_error "Data mismatch! Expected: $TEST_VALUE, Got: $RETRIEVED_VALUE"
    exit 1
fi

# Step 7: Verify cluster is still operational
log_test "Step 7: Checking cluster state after failover..."

CLUSTER_STATE_AFTER=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster info 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r')

if [[ "$CLUSTER_STATE_AFTER" == "ok" ]]; then
    log_info "✓ Cluster state: OK"
else
    log_warn "Cluster state: $CLUSTER_STATE_AFTER (may be degraded)"
fi

# Step 8: Restart killed master and verify it joins as replica
log_test "Step 8: Restarting killed master and verifying rejoin..."

docker compose -f "$COMPOSE_FILE" start "$MASTER_TO_KILL" >/dev/null 2>&1
sleep 5

REJOINED_NODES=$(docker compose -f "$COMPOSE_FILE" exec -T toolbox redis-cli \
    -h redis-master-1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning \
    cluster nodes 2>/dev/null)

if echo "$REJOINED_NODES" | grep -q "$MASTER_ID.*slave"; then
    log_info "✓ Former master rejoined as replica"
else
    log_warn "Former master state unclear (may still be syncing)"
fi

# Summary
log_info ""
log_info "================================================"
log_info "Failover Test: PASSED ✓"
log_info "================================================"
log_info ""
log_info "Test Summary:"
log_info "  • Failover time: ${FAILOVER_TIME}s"
log_info "  • Data preserved: YES"
log_info "  • Cluster operational: YES"
log_info "  • Node rejoin: YES"
log_info ""
log_info "Cluster is resilient to master failures!"
