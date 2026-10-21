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
# Capture stdout AND check exit explicitly — `mapfile -t arr < <(cmd)`
# does NOT propagate cmd's exit code, so we'd silently no-op the gate
# if BASE_REF was unfetched.
if ! new_files_output=$(bash priv/repo/list_new_migrations.sh); then
  echo "::error::lint_migrations: list_new_migrations.sh failed (BASE_REF=$BASE_REF may not be fetched)" >&2
  exit 1
fi

if [ -z "$new_files_output" ]; then
  echo "squawk: no migrations newer than $BASE_REF — nothing to lint"
  exit 0
fi

mapfile -t new_files <<<"$new_files_output"
mapfile -t new_versions < <(printf '%s\n' "${new_files[@]}" | grep -oE '^[0-9]{14}')

# Re-derive base_version locally for `mix ecto.migrate --to` below.
# Empty result here would mean the helper succeeded but this second call
# failed — refuse rather than silently calling `mix ecto.migrate --to ''`
# (which can roll back the entire DB).
base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1)

if [ -z "$base_version" ]; then
  echo "::error::lint_migrations: base_version empty on re-derivation — refusing to run 'mix ecto.migrate --to \"\"'" >&2
  exit 1
fi

# Markers, per migration file:
#
#   # squawk-ignore-file          the file's DDL is not linted at all. For
#                                 schema-restore baselines squawk cannot parse.
#   # squawk-ignore: rule-a, rule-b
#                                 lint the file, minus these rules. Prefer this:
#                                 an empty-table CREATE INDEX needs only
#                                 require-concurrent-index-creation off, not the
#                                 whole file unlinted.
#
# Each new migration is rendered and linted ON ITS OWN, so a marker scopes to
# its file. This used to render all new migrations as one SQL blob and exit on
# the first ignore-file marker, which silently skipped every OTHER new
# migration in the PR (#2095 bundled a marked migration and its rebuild
# migrations were never linted).
#
# A marked file is still migrated: later migrations build on its schema.

# `ban-drop-column` / `ban-drop-table` are ON globally (see .squawk.toml) and
# should stay on: an unintended DROP in a migration that was not meant to drop
# is exactly what they exist to catch.
#
# But a `*_drops.exs` migration's WHOLE PURPOSE is to drop, and the repo
# already gates that separately and more precisely: verify.yml "migration
# gates" extracts what any new migration drops and greps lib/ to prove nothing
# still reads the dropped columns/tables. A blanket ban would make dropping
# unshippable. Scoped to the filename convention, NOT to a global config
# exclusion, so the rules keep gating every other migration.
#
# squawk's `--exclude` REPLACES `.squawk.toml`'s `excluded_rules` rather than
# merging with it (verified: passing the drop rules alone brought
# require-timeout-settings and prefer-robust-stmts back, even with an explicit
# `-c`). So any per-file exclusion must re-state the config's own list.
# Derived from the file rather than duplicated, so the two cannot drift; if the
# config's format ever changes this yields an empty base and CI goes red on the
# re-appearing rules, which is the loud failure we want.
base_excluded=$(sed -n 's/^excluded_rules *= *\[\(.*\)\]/\1/p' ".squawk.toml" |
  tr -d '" ' | tr -d "'")

# Ecto's --log-migrations-sql output to plain SQL. The clean SQL lines have no
# timestamp prefix; each statement is terminated by a params marker (` []`
# inline, or a lone `[]` line).
render_sql() {
  grep -vE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' \
    | grep -vE '^\s*$' \
    | awk '{ t=$0; sub(/[ \t]+$/,"",t);
             if (t=="[]") { if(buf!=""){print buf ";"; buf=""} }
             else if (t ~ / \[\]$/) { sub(/ \[\]$/,"",t); buf=(buf==""?t:buf"\n"t); print buf ";"; buf="" }
             else { buf=(buf==""?t:buf"\n"t) } }
         END { if (buf!="") print buf ";" }'
}

echo "squawk: linting new migrations: ${new_versions[*]}"

# Bring the throwaway DB up to the base branch state, then step through the
# new migrations one at a time, rendering each one's SQL.
mix ecto.migrate --to "$base_version" >/dev/null

tmp_sql="$(mktemp --suffix=.sql)"
trap 'rm -f "$tmp_sql"' EXIT

failed=()
for v in $(printf '%s\n' "${new_versions[@]}" | sort -u); do
  file=$(compgen -G "$MIG_DIR/${v}_*.exs" | head -1)

  mix ecto.migrate --to "$v" --log-migrations-sql 2>/dev/null | render_sql > "$tmp_sql"

  if grep -q "# squawk-ignore-file" "$file"; then
    echo "squawk: skipping ${file##*/} (# squawk-ignore-file)"
    continue
  fi

  if [ ! -s "$tmp_sql" ]; then
    echo "squawk: ${file##*/} rendered no SQL - nothing to lint"
    continue
  fi

  excluded=""
  if [[ "$file" == *_drops.exs ]]; then
    excluded="ban-drop-column,ban-drop-table"
    echo "squawk: ${file##*/} is a *_drops migration - drop rules" \
         "deferred to the reference check in verify.yml migration gates"
  fi
  # `# squawk-ignore: a, b` (the whole line, rule names only). Anything else on
  # the line fails to match, the rules stay on, and squawk goes red: loud.
  file_rules=$(sed -nE 's/^[[:space:]]*# squawk-ignore:[[:space:]]*([a-z0-9-]+([[:space:]]*,[[:space:]]*[a-z0-9-]+)*)[[:space:]]*$/\1/p' "$file" |
    tr -d ' ' | paste -sd, -)
  if [ -n "$file_rules" ]; then
    excluded="${excluded:+$excluded,}$file_rules"
    echo "squawk: ${file##*/} ignores: $file_rules"
  fi

  echo "── ${file##*/} ──"
  cat "$tmp_sql"
  echo "──────────────────"

  exclude_arg=()
  [ -n "$excluded" ] && exclude_arg=("--exclude=${base_excluded:+$base_excluded,}$excluded")

  if ! "$SQUAWK" "${exclude_arg[@]}" "$tmp_sql"; then
    failed+=("${file##*/}")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::squawk: ${#failed[@]} migration(s) failed lint: ${failed[*]}" >&2
  exit 1
fi
