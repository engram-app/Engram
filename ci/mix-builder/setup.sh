#!/usr/bin/env bash
# Build engram-mix-builder:ci and put ci/bin (the containerized `mix`) first
# on PATH for the rest of the job. Usage: setup.sh <base-image>
# One rootless dockerd per runner VM, so after the first job on a VM this is
# a layer-cache hit.
set -euo pipefail
base="${1:?usage: setup.sh <base-image>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
docker build -q -t engram-mix-builder:ci \
  --build-arg "BASE=$base" \
  --build-arg "HEX_MIRROR=${HEX_MIRROR:-}" \
  "$root/ci/mix-builder" >/dev/null
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$root/ci/bin" >> "$GITHUB_PATH"
fi
