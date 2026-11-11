#!/usr/bin/env bash
# test/scripts/render_migration_sql_test.sh
#
# priv/repo/render_migration_sql.sh turns Ecto's --log-migrations-sql output
# into the SQL squawk lints. A query with bind parameters is logged with its
# parameter list (` ["notes", "x"]`); left in, squawk fails the migration with
# a syntax error, and the lint failure skips the CI rollback step (S1 #2528,
# run 42996960663: 020100-020300).
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../priv/repo/render_migration_sql.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Shaped like the CI log of 20261111020100 (timestamped info lines, a blank
# line, DDL with ` []`, a parameterised query, a multi-line one with a nested
# list, a lone `[]`).
input=$(cat <<'LOG'
09:41:54.190 [info] == Running 20261111020100 Engram.Repo.Migrations.AddNameTermsStampExpand.up/0
SET lock_timeout = '5s' []

ALTER TABLE notes ADD COLUMN IF NOT EXISTS name_terms_stamp bytea []
SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2 ["notes", "name_terms_stamp"]
SELECT count(*)
FROM pg_class c
WHERE c.relname = ANY($1) [["notes_name_terms_stale", "folders_name_terms_stale"]]
CREATE TABLE t (id uuid)
[]
09:41:54.207 [info] == Migrated 20261111020100 in 0.0s
LOG
)

expected=$(cat <<'SQL'
SET lock_timeout = '5s';
ALTER TABLE notes ADD COLUMN IF NOT EXISTS name_terms_stamp bytea;
SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2;
SELECT count(*)
FROM pg_class c
WHERE c.relname = ANY($1);
CREATE TABLE t (id uuid);
SQL
)

out=$(bash "$SCRIPT" <<<"$input")
[ "$out" = "$expected" ] || fail "rendered SQL differs:
--- got
$out
--- want
$expected"

# Nothing to render: empty output, exit 0 (the caller's "rendered no SQL").
out=$(printf '09:41:54.190 [info] == Running 1 X.up/0\n\n' | bash "$SCRIPT")
[ -z "$out" ] || fail "expected no SQL, got: $out"

echo "render_migration_sql: ok"
