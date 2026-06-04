#!/usr/bin/env bash
# priv/repo/list_new_migrations.sh
#
# Prints the basenames of migration files in priv/repo/migrations/ whose
# 14-digit version is newer than the highest version present on BASE_REF.
# One filename per line. Empty output (and exit 0) means nothing to lint.
#
# Caller must provide BASE_REF (defaults to origin/main); BASE_REF must
# already be fetched into the local repo.
#
# Used by:
#   - priv/repo/lint_migrations.sh (squawk)
#   - .github/workflows/verify.yml phase-label-required job
#   - .github/workflows/verify.yml contract-phase-references job
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
MIG_DIR="priv/repo/migrations"

base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1 || true)

if [ -z "$base_version" ]; then
  echo "::error::list_new_migrations: could not read migrations from '$BASE_REF' (is it fetched?)" >&2
  exit 1
fi

find "$MIG_DIR" -maxdepth 1 -name '*.exs' -printf '%f\n' \
  | awk -v b="$base_version" 'match($0, /^[0-9]{14}/) {
      v = substr($0, RSTART, RLENGTH)
      if (v > b) print
    }' \
  | sort -u
