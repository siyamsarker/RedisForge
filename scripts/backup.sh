#!/usr/bin/env bash
set -euo pipefail

# Perform AOF snapshot backup and upload to S3 (requires AWS CLI configured)

if [[ -z "${BACKUP_S3_BUCKET:-}" ]]; then
  echo "Set BACKUP_S3_BUCKET env var (e.g., s3://my-bucket/redisforge)" >&2
  exit 1
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR=${BACKUP_DIR:-"$(pwd)/backups"}
mkdir -p "$BACKUP_DIR"

DATA_DIR=${DATA_DIR:-"$(pwd)/data/redis"}
AOF_FILE=$(ls -1t "$DATA_DIR"/appendonly.aof* 2>/dev/null | head -n1 || true)
if [[ -z "$AOF_FILE" ]]; then
  echo "No AOF file found in $DATA_DIR" >&2
  exit 1
fi

ARCHIVE="$BACKUP_DIR/redis-aof-$TIMESTAMP.tar.gz"
tar -C "$DATA_DIR" -czf "$ARCHIVE" "$(basename "$AOF_FILE")" nodes.conf || true

echo "Uploading $ARCHIVE to $BACKUP_S3_BUCKET ..."
aws s3 cp "$ARCHIVE" "$BACKUP_S3_BUCKET/" --only-show-errors
echo "Backup complete: $ARCHIVE"

