#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=${1:-"$(pwd)/logs/redis"}
MAX_SIZE_MB=${2:-1024}
MAX_FILES=${3:-7}

mkdir -p "$LOG_DIR"

rotate() {
  local file=$1
  local size_mb=$(du -m "$file" | awk '{print $1}')
  if (( size_mb >= MAX_SIZE_MB )); then
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mv "$file" "$file.$ts"
    : > "$file"
  fi
}

cleanup() {
  ls -1t "$LOG_DIR"/*.log.* 2>/dev/null | tail -n +$((MAX_FILES+1)) | xargs -r rm -f
}

for f in "$LOG_DIR"/*.log; do
  [[ -f "$f" ]] && rotate "$f"
done
cleanup
echo "Log rotation complete in $LOG_DIR"

