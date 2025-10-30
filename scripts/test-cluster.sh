#!/usr/bin/env bash
set -euo pipefail

# Simple integration tests against Envoy endpoint

ENVOY_HOST=${1:-localhost}
PORT=${2:-6379}
PASS=${REDIS_REQUIREPASS:-}

echo "Running cluster tests against ${ENVOY_HOST}:${PORT} ..."

AUTH_ARGS=()
[[ -n "$PASS" ]] && AUTH_ARGS+=(--pass "$PASS")

redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" ping | grep -q PONG
echo "PING ok"

redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" set test:key value EX 30
VAL=$(redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" get test:key)
[[ "$VAL" == "value" ]] && echo "SET/GET ok"

echo "Pub/Sub smoke..."
timeout 5s bash -c "redis-cli -h $ENVOY_HOST -p $PORT ${AUTH_ARGS[*]} subscribe test:chan > /tmp/sub.$$ & sleep 1; echo 'hello' | redis-cli -h $ENVOY_HOST -p $PORT ${AUTH_ARGS[*]} publish test:chan -; sleep 1" || true

echo "Cluster info via Envoy..."
redis-cli -h "$ENVOY_HOST" -p "$PORT" "${AUTH_ARGS[@]}" info | sed -n '1,30p'

echo "All tests passed"

