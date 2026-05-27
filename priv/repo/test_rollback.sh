#!/usr/bin/env bash
#
# Verifies the migrations new on this branch roll back AND re-apply cleanly —
# i.e. their `down` blocks actually work. Full-history `rollback --all` is not
# possible: some legacy migrations are intentionally irreversible (e.g. the
# encryption phase-B plaintext drops raise in `down`), so this scopes to the
# migrations this branch is responsible for.
#
# Caller must provide:
#   DATABASE_URL  — a FRESH, EMPTY database (it gets migrated + rolled back)
#   MIX_ENV=test  — reuses the compiled _build/test
#   BASE_REF      — git ref to diff against (default origin/main); must be fetched
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
MIG_DIR="priv/repo/migrations"

base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1 || true)

if [ -z "$base_version" ]; then
  echo "::error::rollback test: could not read migrations from '$BASE_REF' (is it fetched?)"
  exit 1
fi

n=$(find "$MIG_DIR" -maxdepth 1 -name '*.exs' -printf '%f\n' \
  | grep -oE '^[0-9]{14}' | sort -u | awk -v b="$base_version" '$0 > b' | wc -l)

if [ "$n" -eq 0 ]; then
  echo "rollback test: no migrations newer than $BASE_REF — nothing to check"
  exit 0
fi

echo "rollback test: $n new migration(s) — migrate → rollback → re-migrate"
mix ecto.migrate
mix ecto.rollback --step "$n"
mix ecto.migrate
echo "rollback test: new migrations reverse and re-apply cleanly ✓"
