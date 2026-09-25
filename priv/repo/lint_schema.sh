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
# Findings that are deliberate go in WAIVERS below, which matches on lint AND
# object so a waiver cannot silence the same lint elsewhere in the schema.
#
# Usage: pipe splinter's pipe-delimited rows on stdin, e.g.
#   docker exec -i "$PG" psql -U engram -d engram_test -At -F'|' \
#     < priv/repo/splinter.sql | bash priv/repo/lint_schema.sh
set -euo pipefail

IGNORE='^(unused_index)$'

# Narrow waivers, matched against the FORMATTED finding line so each one names
# the lint AND the object it applies to. Prefer this over adding a bare lint
# name to IGNORE above, which disables that lint for the whole schema.
#
# multiple_permissive_policies on public.api_keys: `api_keys_discovery` is a
# deliberate SECOND permissive SELECT policy. Credential lookup discovers the
# tenant and therefore cannot set one first, so without it every API-key
# request 401s with `invalid_key`. Collapsing the two into
# `tenant_isolation_api_keys` would satisfy the lint but widen DELETE, which
# would then consult the permissive predicate instead of the strict one. The
# advisory is about per-query policy evaluation cost; this table is read once
# per request by unique index, so the cost is noise.
# See docs/context/rls-cutover-breaks-api-key-auth.md.
#
# multiple_permissive_policies for role engram_maintenance, pairing
# `maintenance_all` with a table's `tenant_isolation_*`: deliberate. RDS cannot
# grant BYPASSRLS to a custom role, so the maintenance pool's cross-tenant
# reach IS a second permissive policy scoped `TO engram_maintenance`. The
# tenant policies apply to PUBLIC, so that role always sees two. Only the
# maintenance pool (a few cron jobs, never a request) pays the extra
# evaluation, and its `true` predicate short-circuits the OR. Matched on the
# role AND the exact two-policy set, so a third permissive policy on any
# table still fires. See docs/context/maintenance-db-role.md.
WAIVERS='multiple_permissive_policies.*public\.api_keys|multiple_permissive_policies.*role [^ ]*engram_maintenance[^ ]* .*\{maintenance_all,tenant_isolation_[a-z_]+\}'

# `|| true`: grep exits 1 when it filters every line, which is a pass, not an
# error. Without it `set -e` would abort here on a clean schema.
findings=$(awk -F'|' -v ig="$IGNORE" \
  'NF > 3 && $3 != "" && $1 !~ ig { printf "  [%s] %s — %s\n", $3, $1, $7 }' \
  | grep -vE "$WAIVERS" || true)

if [ -n "$findings" ]; then
  echo "::error::splinter reported schema advisories (fix or justify):"
  echo "$findings"
  exit 1
fi

echo "splinter: no actionable schema findings"
