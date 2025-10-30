#!/usr/bin/env bash
set -euo pipefail

################################################################################
# RedisForge - Log Rotation Script
# Rotates Redis logs based on size and keeps a specified number of rotated files
################################################################################

# Configuration
LOG_DIR=${1:-"$(pwd)/logs/redis"}
MAX_SIZE_MB=${2:-1024}
MAX_FILES=${3:-7}

# Validation
if [[ ! -d "$LOG_DIR" ]]; then
  echo "ERROR: Log directory does not exist: $LOG_DIR" >&2
  exit 1
fi

if ! [[ "$MAX_SIZE_MB" =~ ^[0-9]+$ ]] || (( MAX_SIZE_MB <= 0 )); then
  echo "ERROR: MAX_SIZE_MB must be a positive integer" >&2
  exit 1
fi

if ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]] || (( MAX_FILES <= 0 )); then
  echo "ERROR: MAX_FILES must be a positive integer" >&2
  exit 1
fi

echo "Log Rotation Configuration:"
echo "  Directory: $LOG_DIR"
echo "  Max Size: ${MAX_SIZE_MB}MB"
echo "  Max Rotated Files: $MAX_FILES"
echo ""

# Function to rotate a single log file
rotate_log() {
  local file=$1
  
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  
  # Get file size in MB (portable across Linux and macOS)
  local size_bytes
  size_bytes=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
  local size_mb=$(( size_bytes / 1024 / 1024 ))
  
  if (( size_mb >= MAX_SIZE_MB )); then
    local timestamp
    timestamp=$(date +%Y%m%dT%H%M%SZ)
    local rotated_file="${file}.${timestamp}"
    
    echo "Rotating: $(basename "$file") (${size_mb}MB > ${MAX_SIZE_MB}MB)"
    
    if mv "$file" "$rotated_file" 2>/dev/null; then
      # Create empty log file with same permissions
      touch "$file"
      chmod --reference="$rotated_file" "$file" 2>/dev/null || chmod 644 "$file"
      
      # Compress rotated log in background
      if command -v gzip >/dev/null 2>&1; then
        (gzip "$rotated_file" &)
        echo "  → Compressed: $(basename "$rotated_file").gz"
      else
        echo "  → Rotated: $(basename "$rotated_file")"
      fi
    else
      echo "  ERROR: Failed to rotate $file" >&2
      return 1
    fi
  fi
  
  return 0
}

# Function to cleanup old rotated logs
cleanup_old_logs() {
  local pattern=$1
  local count=0
  
  # Find and sort rotated logs by modification time (newest first)
  while IFS= read -r file; do
    count=$((count + 1))
    if (( count > MAX_FILES )); then
      echo "Removing old log: $(basename "$file")"
      rm -f "$file"
    fi
  done < <(find "$LOG_DIR" -name "$pattern" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null)
}

# Main rotation logic
echo "Checking log files..."
rotated_count=0
error_count=0

for log_file in "$LOG_DIR"/*.log; do
  if [[ -f "$log_file" ]]; then
    if rotate_log "$log_file"; then
      if [[ -f "${log_file}.$(date +%Y%m%dT*)" ]] 2>/dev/null; then
        rotated_count=$((rotated_count + 1))
      fi
    else
      error_count=$((error_count + 1))
    fi
  fi
done

# Cleanup old rotated logs
echo ""
echo "Cleaning up old rotated logs..."
cleanup_old_logs "*.log.*"

echo ""
echo "Log rotation complete:"
echo "  Files rotated: $rotated_count"
echo "  Errors: $error_count"

if (( error_count > 0 )); then
  exit 1
fi

