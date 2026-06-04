#!/usr/bin/env bash
#
# Prints the filenames (basename only) of migrations that are NEW on this
# branch relative to BASE_REF (default: origin/main).
#
# Output: one filename per line, e.g.
#   20260604120000_add_foo.exs
#   20260604120001_add_bar.exs
#
# Exit 0 with no output when there are no new migrations.
# Exit 1 (with an error message on stderr) when BASE_REF cannot be read.
#
# Caller must have already fetched BASE_REF (the n1-compat CI job does this).
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
MIG_DIR="priv/repo/migrations"

# Highest migration version already on the base branch.
base_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIG_DIR" 2>/dev/null \
  | grep -oE '[0-9]{14}' | sort -u | tail -1 || true)

if [ -z "$base_version" ]; then
  echo "list_new_migrations: could not read migrations from '$BASE_REF' (is it fetched?)" >&2
  exit 1
fi

# Emit basenames of migrations newer than the base branch's tip.
find "$MIG_DIR" -maxdepth 1 -name '*.exs' -printf '%f\n' \
  | sort \
  | awk -v b="${base_version}" '{ v=$0; sub(/_.*/, "", v); if (v > b) print $0 }'
