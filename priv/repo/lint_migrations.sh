#!/usr/bin/env bash
#
# Lints the DDL of migrations new on this branch with squawk
# (https://squawk.dev), catching unsafe migration patterns (dropping columns,
# adding NOT NULL columns, type changes, blocking constraints, etc.) before
# they merge. Ecto-incompatible rules are excluded in .squawk.toml.
#
# Ecto migrations are imperative Elixir, so the DDL is rendered by migrating a
# throwaway database to the latest version present on BASE_REF and then running
# the new migrations with --log-migrations-sql, capturing only their SQL.
#
# Caller must provide:
#   DATABASE_URL  — a FRESH, EMPTY database to render against (it gets migrated)
#   MIX_ENV=test  — reuses the compiled _build/test (no dev recompile in CI)
#   BASE_REF      — git ref to diff against (default origin/main); must be fetched
#   SQUAWK_BIN    — path to the squawk binary (default: squawk on PATH)
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
SQUAWK="${SQUAWK_BIN:-squawk}"
MIG_DIR="priv/repo/migrations"

# Migrations in the working tree newer than the base branch's tip.
mapfile -t new_files < <(bash priv/repo/list_new_migrations.sh)
mapfile -t new_versions < <(printf '%s\n' "${new_files[@]}" | grep -oE '^[0-9]{14}')

if [ "${#new_versions[@]}" -eq 0 ]; then
  echo "squawk: no migrations newer than $BASE_REF — nothing to lint"
  exit 0
fi

# Re-derive base_version locally for `mix ecto.migrate --to` below
# (the helper doesn't print it).
base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1)

# Skip lint entirely if any new migration file carries the
# `# squawk-ignore-file` marker. Used for schema-restore baselines whose
# rendered DDL is the entire schema (FORCE ROW LEVEL SECURITY, sequences,
# ALTER ... OWNER, etc.) — squawk's parser chokes on the advanced syntax
# and the lint adds no value over the existing schema diff gate.
for v in "${new_versions[@]}"; do
  if grep -q "# squawk-ignore-file" "$MIG_DIR"/${v}_*.exs 2>/dev/null; then
    echo "squawk: skipping — ${v} carries # squawk-ignore-file marker"
    exit 0
  fi
done

echo "squawk: linting new migrations: ${new_versions[*]}"

# Bring the throwaway DB up to the base branch state, then render only the new
# migrations' SQL. The clean SQL lines have no timestamp prefix; each statement
# is terminated by a params marker (` []` inline, or a lone `[]` line).
mix ecto.migrate --to "$base_version" >/dev/null

tmp_sql="$(mktemp --suffix=.sql)"
trap 'rm -f "$tmp_sql"' EXIT

mix ecto.migrate --log-migrations-sql 2>/dev/null \
  | grep -vE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' \
  | grep -vE '^\s*$' \
  | awk '{ t=$0; sub(/[ \t]+$/,"",t);
           if (t=="[]") { if(buf!=""){print buf ";"; buf=""} }
           else if (t ~ / \[\]$/) { sub(/ \[\]$/,"",t); buf=(buf==""?t:buf"\n"t); print buf ";"; buf="" }
           else { buf=(buf==""?t:buf"\n"t) } }
       END { if (buf!="") print buf ";" }' > "$tmp_sql"

if [ ! -s "$tmp_sql" ]; then
  echo "squawk: rendered no SQL — nothing to lint"
  exit 0
fi

echo "── rendered DDL ──"
cat "$tmp_sql"
echo "──────────────────"

"$SQUAWK" "$tmp_sql"
