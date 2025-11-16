#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-config/tls/dev}"
COMMON_NAME="${COMMON_NAME:-redisforge.local}"
DAYS="${DAYS:-3650}"
KEY_BITS="${KEY_BITS:-4096}"

mkdir -p "${OUTPUT_DIR}"
openssl req -x509 -nodes -days "$DAYS" -newkey rsa:"$KEY_BITS" \
  -keyout "${OUTPUT_DIR}/server.key" \
  -out "${OUTPUT_DIR}/server.crt" \
  -subj "/CN=${COMMON_NAME}"
cp "${OUTPUT_DIR}/server.crt" "${OUTPUT_DIR}/ca.crt"
chmod 600 "${OUTPUT_DIR}/server.key"
