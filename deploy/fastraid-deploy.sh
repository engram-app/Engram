#!/bin/bash
# Deploy Engram to FastRaid (Unraid). Runs on the FastRaid host itself.
#
# Two containers run from the same image, different shapes:
#   engram-saas      — port 8000 — Voyage embeddings + Clerk auth (engram.ras.band)
#   engram-selfhost  — port 8001 — Ollama embeddings + local auth (engram.ax)
#
# Usage: bash fastraid-deploy.sh <version>
#   version: semver from mix.exs (e.g. 0.5.10)
#
# Sequential deploy (SaaS first, then selfhost) so a broken image fails fast
# on the lower-traffic side without touching the production-facing container
# UNTIL it's already proven healthy. `set -e` halts before selfhost runs if
# saas fails health-check.
set -euo pipefail

VERSION="${1:?Usage: fastraid-deploy.sh <version>}"
IMAGE="ghcr.io/rasbandit/engram"
TEMPLATE_DIR="/boot/config/plugins/dockerMan/templates-user"
UPDATE_CONTAINER="/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container"

# name:port pairs, ordered. SaaS first so we don't touch selfhost if SaaS fails.
CONTAINERS=(
  "engram-saas:8000"
  "engram-selfhost:8001"
)

echo "==> Pulling ${IMAGE}:${VERSION}"
docker pull "${IMAGE}:${VERSION}"

# Tag as :latest so the Unraid GUI shows consistent state across both containers.
docker tag "${IMAGE}:${VERSION}" "${IMAGE}:latest"

deploy_one() {
  local name="$1" port="$2"
  local template="${TEMPLATE_DIR}/my-${name}.xml"

  if [ ! -f "$template" ]; then
    echo "ERROR: Unraid template missing: ${template}" >&2
    return 1
  fi

  sed -i "s|<Repository>${IMAGE}:[^<]*</Repository>|<Repository>${IMAGE}:${VERSION}</Repository>|" "$template"
  echo "==> ${name}: template pinned to ${VERSION}"

  # update_container only auto-starts if the container was running when it
  # begins, so the container must still be running here — do NOT stop/rm
  # before this line.
  echo "==> ${name}: updating container"
  "$UPDATE_CONTAINER" "$name"

  echo "==> ${name}: waiting for /api/health to report ${VERSION}"
  for i in $(seq 1 30); do
    local health
    health=$(curl -sf "http://localhost:${port}/api/health" 2>/dev/null || true)
    if [ -n "$health" ]; then
      local running
      running=$(echo "$health" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
      if [ "$running" = "$VERSION" ]; then
        echo "==> ${name}: healthy at ${VERSION}"
        return 0
      fi
    fi
    sleep 2
  done

  echo "ERROR: ${name} not healthy at ${VERSION} after 60s" >&2
  docker logs --tail 50 "$name" 2>&1 || true
  return 1
}

for entry in "${CONTAINERS[@]}"; do
  name="${entry%%:*}"
  port="${entry##*:}"
  deploy_one "$name" "$port"
done

echo "==> All Engram containers deployed at ${VERSION}"
