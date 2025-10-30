#!/usr/bin/env bash
set -euo pipefail

################################################################################
# RedisForge - AOF Backup Script
# Performs AOF snapshot backup and uploads to S3 (requires AWS CLI configured)
################################################################################

# Validate required environment variables
if [[ -z "${BACKUP_S3_BUCKET:-}" ]]; then
  echo "ERROR: BACKUP_S3_BUCKET environment variable not set" >&2
  echo "Example: export BACKUP_S3_BUCKET=s3://my-bucket/redisforge" >&2
  exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: AWS CLI not installed. Install with: pip install awscli" >&2
  exit 1
fi

# Configuration
TIMESTAMP=$(date +%Y%m%dT%H%M%SZ)
BACKUP_DIR=${BACKUP_DIR:-"$(pwd)/backups"}
DATA_DIR=${DATA_DIR:-"$(pwd)/data/redis"}

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Find AOF file (handle multiple AOF files from Redis 7+)
AOF_FILES=()
while IFS= read -r -d '' file; do
  AOF_FILES+=("$file")
done < <(find "$DATA_DIR" -name "appendonly*.aof" -print0 2>/dev/null | sort -z)

if [[ ${#AOF_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No AOF files found in $DATA_DIR" >&2
  echo "Make sure Redis is configured with AOF persistence (appendonly yes)" >&2
  exit 1
fi

echo "Found ${#AOF_FILES[@]} AOF file(s) to backup"

# Create archive
ARCHIVE="$BACKUP_DIR/redis-aof-$TIMESTAMP.tar.gz"
echo "Creating archive: $ARCHIVE"

# Build tar command with all AOF files and cluster config
TAR_ARGS=()
for aof in "${AOF_FILES[@]}"; do
  TAR_ARGS+=(-C "$DATA_DIR" "$(basename "$aof")")
done

# Add nodes.conf if it exists (cluster configuration)
if [[ -f "$DATA_DIR/nodes.conf" ]]; then
  TAR_ARGS+=(-C "$DATA_DIR" "nodes.conf")
  echo "Including nodes.conf (cluster configuration)"
fi

# Create compressed archive
if ! tar -czf "$ARCHIVE" "${TAR_ARGS[@]}"; then
  echo "ERROR: Failed to create archive" >&2
  exit 1
fi

# Verify archive was created and is not empty
if [[ ! -s "$ARCHIVE" ]]; then
  echo "ERROR: Archive is empty or doesn't exist" >&2
  exit 1
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | awk '{print $1}')
echo "Archive created: $ARCHIVE ($ARCHIVE_SIZE)"

# Upload to S3
echo "Uploading to $BACKUP_S3_BUCKET ..."
if ! aws s3 cp "$ARCHIVE" "$BACKUP_S3_BUCKET/" --only-show-errors; then
  echo "ERROR: Failed to upload to S3" >&2
  exit 1
fi

echo "✓ Backup complete: $ARCHIVE"
echo "✓ Uploaded to: $BACKUP_S3_BUCKET/$(basename "$ARCHIVE")"

# Optional: Clean up old local backups (keep last 7 days)
if [[ -n "${BACKUP_RETENTION_DAYS:-}" ]]; then
  echo "Cleaning up backups older than ${BACKUP_RETENTION_DAYS} days..."
  find "$BACKUP_DIR" -name "redis-aof-*.tar.gz" -type f -mtime +"${BACKUP_RETENTION_DAYS}" -delete
  echo "✓ Cleanup complete"
fi

