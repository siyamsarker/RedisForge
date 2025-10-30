#!/usr/bin/env bash
set -euo pipefail

# DEPRECATED: Use scripts/setup-exporters.sh instead
# This script is kept for backward compatibility

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Note: This script has been replaced by setup-exporters.sh"
echo "RedisForge no longer deploys Prometheus/Grafana - use your existing monitoring infrastructure."
echo ""
echo "Running setup-exporters.sh to deploy redis_exporter and node_exporter..."
echo ""

"${SCRIPT_DIR}/setup-exporters.sh"