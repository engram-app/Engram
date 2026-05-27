#!/usr/bin/env bash
#
# Schema linter gate for CI. Runs Supabase's splinter
# (https://github.com/supabase/splinter, vendored as splinter.sql) against an
# already-migrated database and fails if it reports any actionable finding.
#
# On a plain Postgres (no pg_graphql extension, no anon/authenticated roles)
# the Supabase-API-specific lints (table-exposed, rls_disabled_in_public) do
# not fire, so this surfaces only genuine schema issues: per-row RLS policies
# (auth_rls_initplan), unindexed foreign keys, duplicate indexes, missing
# primary keys, security-definer views, etc.
#
# `unused_index` is ignored: it depends on pg_stat scan counts, which are
# empty on a freshly-migrated CI database, so every index would false-positive.
#
# Usage: pipe splinter's pipe-delimited rows on stdin, e.g.
#   docker exec -i "$PG" psql -U engram -d engram_test -At -F'|' \
#     < priv/repo/splinter.sql | bash priv/repo/lint_schema.sh
set -euo pipefail

IGNORE='^(unused_index)$'

findings=$(awk -F'|' -v ig="$IGNORE" \
  'NF > 3 && $3 != "" && $1 !~ ig { printf "  [%s] %s — %s\n", $3, $1, $7 }')

if [ -n "$findings" ]; then
  echo "::error::splinter reported schema advisories (fix or justify):"
  echo "$findings"
  exit 1
fi

echo "splinter: no actionable schema findings"
