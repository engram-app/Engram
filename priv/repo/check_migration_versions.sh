#!/usr/bin/env bash
# priv/repo/check_migration_versions.sh
#
# Fails when two migration files share a version (the leading integer before
# the first underscore). Ecto keys migrations by version only:
#   - both files in one tree: the migrator raises "migration version ... is
#     duplicated" at boot, and every ECS task crashes;
#   - shipped in separate releases: the second file is never run, because the
#     version is already in schema_migrations. Silent, forever.
# Each PR is green alone, so only a cross-branch check sees it (PRs #2513 and
# #2521 both added 20261107140000_*.exs).
#
# Usage (from the repo root):
#   check_migration_versions.sh tree [DIR]
#       every *.exs in DIR (default priv/repo/migrations) has a unique version.
#   check_migration_versions.sh cross BASE LABEL REF [LABEL REF ...]
#       no version this branch ADDS since BASE appears under a different file
#       name in any REF's tree. Same name = same migration (stacked PRs).
#   check_migration_versions.sh open-prs BASE
#       `cross` against origin/main and every other open, same-repo PR head,
#       fetched in ONE git fetch. Fork or vanished branches warn, not fail.
#       Needs gh auth (GH_TOKEN) and GH_REPO.
set -euo pipefail

MIG_DIR="${MIG_DIR:-priv/repo/migrations}"

# stdin: paths, one per line. stdout: "version<TAB>basename", migrations only.
versions() {
  awk -F/ '$NF ~ /^[0-9]+_.*\.exs$/ { split($NF, p, "_"); print p[1] "\t" $NF }'
}

cmd_tree() {
  local dir="${1:-$MIG_DIR}" dups
  dups=$(find "$dir" -maxdepth 1 -name '*.exs' -printf '%f\n' | versions | sort |
    awk -F'\t' '{ n[$1]++; f[$1] = f[$1] " " $2 }
      END { for (v in n) if (n[v] > 1) print v ":" f[v] }')
  if [ -n "$dups" ]; then
    echo "::error::Duplicate migration versions in $dir (Ecto crashes at boot on these):"
    printf '  %s\n' "$dups"
    return 1
  fi
  echo "OK - every migration version in $dir is unique."
}

cmd_cross() {
  local base=$1; shift
  local added fail=0 label ref hits
  added=$(git diff --name-only --diff-filter=A "$base" HEAD -- "$MIG_DIR" | versions)
  if [ -z "$added" ]; then
    echo "No migrations added since $base - nothing to cross-check."
    return 0
  fi
  while [ $# -ge 2 ]; do
    label=$1 ref=$2; shift 2
    # Lines "version<TAB>ours<TAB>theirs" where the version matches, name differs.
    hits=$(git ls-tree -r --name-only "$ref" -- "$MIG_DIR" | versions |
      awk -F'\t' 'NR == FNR { ours[$1] = $2; next }
        ($1 in ours) && ours[$1] != $2 { print $1 "\t" ours[$1] "\t" $2 }' \
        <(printf '%s\n' "$added") -)
    while IFS=$'\t' read -r v ours theirs; do
      [ -n "$v" ] || continue
      fail=1
      echo "::error file=$MIG_DIR/$ours::Migration version $v is also used by $label ($MIG_DIR/$theirs). Renumber one: Ecto crashes on the duplicate, or silently skips the later one."
    done <<<"$hits"
  done
  [ "$fail" -eq 0 ] && echo "OK - no added migration version collides with main or another open PR."
  return "$fail"
}

cmd_open_prs() {
  local base=$1 self prs heads num branch fork
  self=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}
  prs=$(gh pr list --state open --limit 500 \
    --json number,headRefName,isCrossRepository \
    --jq '.[] | [.number, .headRefName, .isCrossRepository] | @tsv')
  heads=$(git ls-remote --heads origin | sed 's#.*refs/heads/##')
  local targets=("main" "origin/main") refspecs=()
  while IFS=$'\t' read -r num branch fork; do
    [ -n "$num" ] || continue
    [ "$branch" = "$self" ] && [ "$fork" = false ] && continue
    if [ "$fork" = true ] || ! grep -qxF -- "$branch" <<<"$heads"; then
      echo "::warning::PR #$num ($branch) is from a fork or its branch is gone; not checked for migration version collisions."
      continue
    fi
    refspecs+=("+refs/heads/$branch:refs/migration-guard/$num")
    targets+=("PR #$num" "refs/migration-guard/$num")
  done <<<"$prs"
  # ponytail: one fetch of every open head; objects are mostly shared with main.
  [ ${#refspecs[@]} -eq 0 ] || git fetch -q --no-tags origin "${refspecs[@]}"
  cmd_cross "$base" "${targets[@]}"
}

case "${1:-}" in
  tree) shift; cmd_tree "$@" ;;
  cross) shift; cmd_cross "$@" ;;
  open-prs) shift; cmd_open_prs "$@" ;;
  *) echo "usage: $0 tree [DIR] | cross BASE LABEL REF... | open-prs BASE" >&2; exit 2 ;;
esac
