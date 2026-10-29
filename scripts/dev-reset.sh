#!/usr/bin/env bash
# dev-reset.sh — wipe the local dev data stores for a clean slate.
#
# Resets all three persistent dev stores in sequence:
#   1. Qdrant collection (docker-compose.dev.yml, or wherever QDRANT_URL points)
#   2. MinIO bucket on the local Docker stack
#   3. Postgres engram_dev DB (opt-in via --postgres)
#
# Usage:
#   ./scripts/dev-reset.sh                       # qdrant + minio only
#   ./scripts/dev-reset.sh --postgres            # also drop+create engram_dev
#   ./scripts/dev-reset.sh --qdrant-only         # just the qdrant collection
#   ./scripts/dev-reset.sh --minio-only          # just the minio bucket
#
# Reads .env.local for QDRANT_URL / QDRANT_COLLECTION / STORAGE_* defaults.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.local"

[[ -f "${ENV_FILE}" ]] && set -a && source "${ENV_FILE}" && set +a

QDRANT_URL="${QDRANT_URL:-http://localhost:6334}"
QDRANT_COLLECTION="${QDRANT_COLLECTION:-obsidian_notes}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_BUCKET="${STORAGE_BUCKET:-engram-attachments}"
MINIO_ACCESS_KEY="${STORAGE_ACCESS_KEY_ID:-minioadmin}"
MINIO_SECRET_KEY="${STORAGE_SECRET_ACCESS_KEY:-minioadmin}"
PG_DB="${POSTGRES_DB:-engram_dev}"

DO_QDRANT=1
DO_MINIO=1
DO_POSTGRES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres)    DO_POSTGRES=1 ;;
    --qdrant-only) DO_QDRANT=1; DO_MINIO=0; DO_POSTGRES=0 ;;
    --minio-only)  DO_QDRANT=0; DO_MINIO=1; DO_POSTGRES=0 ;;
    --pg-only)     DO_QDRANT=0; DO_MINIO=0; DO_POSTGRES=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${DO_QDRANT}" == 1 ]]; then
  echo ">> Qdrant: DELETE ${QDRANT_URL}/collections/${QDRANT_COLLECTION}"
  curl -fsS --max-time 5 -X DELETE "${QDRANT_URL}/collections/${QDRANT_COLLECTION}" \
       ${QDRANT_API_KEY:+-H "api-key: ${QDRANT_API_KEY}"} \
       || echo "   (collection did not exist — ok)"
fi

if [[ "${DO_MINIO}" == 1 ]]; then
  echo ">> MinIO: wipe bucket ${MINIO_BUCKET} on ${MINIO_ENDPOINT}"
  if ! command -v mc >/dev/null 2>&1; then
    echo "   mc not installed — install with: brew install minio/stable/mc" >&2
    exit 2
  fi
  mc alias set engram-dev "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null
  mc rm --recursive --force "engram-dev/${MINIO_BUCKET}/" 2>/dev/null || \
    echo "   (bucket empty or missing — ok)"
fi

if [[ "${DO_POSTGRES}" == 1 ]]; then
  echo ">> Postgres: drop + recreate ${PG_DB}"
  ( cd "${ROOT}" && MIX_ENV=dev mix ecto.drop && MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate )
fi

echo ">> done."
