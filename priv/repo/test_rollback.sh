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

# Capture stdout AND check exit explicitly — mirrors lint_migrations.sh pattern.
# `mapfile -t arr < <(cmd)` does NOT propagate cmd's exit code, so an
# unfetched BASE_REF would silently make this gate a no-op.
if ! new_files_output=$(bash priv/repo/list_new_migrations.sh); then
  echo "::error::rollback test: list_new_migrations.sh failed (BASE_REF=$BASE_REF may not be fetched)" >&2
  exit 1
fi

if [ -z "$new_files_output" ]; then
  echo "rollback test: no migrations newer than $BASE_REF — nothing to check"
  exit 0
fi

mapfile -t new_files <<<"$new_files_output"
mapfile -t new_versions < <(printf '%s\n' "${new_files[@]}" | grep -oE '^[0-9]{14}')
n=${#new_versions[@]}

# Re-derive base_version locally for `mix ecto.migrate --to` below.
# Refuse rather than silently calling `mix ecto.migrate --to ''` (which
# can roll back the entire DB).
base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1)

if [ -z "$base_version" ]; then
  echo "::error::rollback test: base_version empty on re-derivation — refusing to run 'mix ecto.migrate --to \"\"'" >&2
  exit 1
fi

# Each new migration is applied, rolled back and re-applied on its own, in
# order, so a `# rollback-irreversible` marker (schema-restore baselines whose
# `down` raises by design) exempts only its own file. This used to exit on the
# first marker and leave every OTHER new migration's `down` untested.
mix ecto.migrate --to "$base_version"

echo "rollback test: $n new migration(s) - migrate, rollback, re-migrate each"
for v in $(printf '%s\n' "${new_versions[@]}" | sort -u); do
  file=$(compgen -G "$MIG_DIR/${v}_*.exs" | head -1)
  mix ecto.migrate --to "$v"
  if grep -qE '^[[:space:]]*# rollback-irreversible' "$file"; then
    echo "rollback test: ${file##*/} carries # rollback-irreversible - applied, not rolled back"
    continue
  fi
  mix ecto.rollback --step 1
  mix ecto.migrate --to "$v"
done
echo "rollback test: new migrations reverse and re-apply cleanly"
