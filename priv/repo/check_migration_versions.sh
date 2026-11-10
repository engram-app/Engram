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
# When two PRs collide, BOTH go red. After renumbering one, re-run the other's
# CI (a re-run re-fetches the open PRs).
#
# Same file name on two branches counts as one migration (stacked PRs). Two
# independent PRs adding the SAME name with different content are not flagged
# here: git reports an add/add conflict, and after a rebase the
# migrations-immutable check fires on the edited file.
#
# Usage (from the repo root):
#   check_migration_versions.sh tree [DIR]
#       every *.exs in DIR (default priv/repo/migrations) has a unique version.
#   check_migration_versions.sh cross BASE LABEL REF [LABEL REF ...]
#       no version this branch ADDS since BASE appears under a different file
#       name in any REF's tree. Same name = same migration (stacked PRs).
#   check_migration_versions.sh open-prs BASE
#       `cross` against origin/main and every other open PR's
#       refs/pull/<n>/head (covers forks, outlives branch deletion), fetched
#       from GitHub directly in one fetch, per-ref on failure. A ref that
#       cannot be fetched FAILS if its PR is still open, warns if it closed.
#       Needs gh auth (GH_TOKEN) and GH_REPO.
set -euo pipefail

MIG_DIR="${MIG_DIR:-priv/repo/migrations}"

# stdin: paths, one per line. stdout: "version<TAB>basename", migrations only.
# Ecto compares versions as integers, so leading zeros are dropped.
versions() {
  awk -F/ '$NF ~ /^[0-9]+_.*\.exs$/ {
    split($NF, p, "_"); v = p[1]; sub(/^0+/, "", v); if (v == "") v = "0"
    print v "\t" $NF
  }'
}

# Workflow-command escaping for annotation text (a branch name is input).
esc() { local s=${1//'%'/%25}; s=${s//$'\r'/%0D}; printf '%s' "${s//$'\n'/%0A}"; }

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
  added=$(git diff --name-only --no-renames --diff-filter=A "$base" HEAD -- "$MIG_DIR" | versions)
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
      echo "::error file=$(esc "$MIG_DIR/$ours" | sed 's/:/%3A/g; s/,/%2C/g')::Migration version $v is also used by $(esc "$label") ($(esc "$MIG_DIR/$theirs")). Renumber one: Ecto crashes on the duplicate, or silently skips the later one. Both PRs are red; re-run the other one's CI after renumbering."
    done <<<"$hits"
  done
  [ "$fail" -eq 0 ] && echo "OK - no added migration version collides with main or another open PR."
  return "$fail"
}

cmd_open_prs() {
  local base=$1 self prs num branch fork state fail=0
  self=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}
  # The runners rewrite github.com/engram-app/* to a LAN git cache that can
  # lag a fresh push. A URL with credentials does not match the insteadOf
  # prefix, so it reads GitHub itself (docs/context/ci-runner-network-and-disk-gotchas.md).
  local url=${PR_FETCH_URL:-https://x-access-token:${GH_TOKEN:-}@github.com/${GH_REPO:?GH_REPO unset}.git}
  local limit=${PR_LIST_LIMIT:-500}
  prs=$(gh pr list --state open --limit "$limit" \
    --json number,headRefName,isCrossRepository \
    --jq '.[] | [.number, .headRefName, .isCrossRepository] | @tsv')
  if [ "$(grep -c . <<<"$prs")" -ge "$limit" ]; then
    echo "::error::gh pr list returned $limit PRs, its cap; the list may be truncated, so some open PRs would go unchecked. Raise PR_LIST_LIMIT in priv/repo/check_migration_versions.sh."
    return 1
  fi
  local nums=() names=() refspecs=() targets=("main" "origin/main")
  while IFS=$'\t' read -r num branch fork; do
    [ -n "$num" ] || continue
    [ "$branch" = "$self" ] && [ "$fork" = false ] && continue
    nums+=("$num") names+=("$branch")
    refspecs+=("+refs/pull/$num/head:refs/migration-guard/$num")
  done <<<"$prs"
  if [ ${#refspecs[@]} -gt 0 ] && ! git fetch -q --no-tags "$url" "${refspecs[@]}" 2>/dev/null; then
    # One vanished ref aborts a batched fetch; retry each ref alone.
    for i in "${!nums[@]}"; do
      git fetch -q --no-tags "$url" "${refspecs[$i]}" 2>/dev/null ||
        git update-ref -d "refs/migration-guard/${nums[$i]}" 2>/dev/null || true
    done
  fi
  for i in "${!nums[@]}"; do
    num=${nums[$i]} branch=$(esc "${names[$i]}")
    if git rev-parse -q --verify "refs/migration-guard/$num^{commit}" >/dev/null; then
      targets+=("PR #$num" "refs/migration-guard/$num")
      continue
    fi
    if ! state=$(gh pr view "$num" --json state --jq .state); then
      echo "::error::Could not read the state of PR #$num ($branch) after its head failed to fetch (gh error above). Re-run this job."
      return 1
    fi
    if [ "$state" = OPEN ]; then
      fail=1
      echo "::error::PR #$num ($branch) is open but its head could not be fetched, so its migrations cannot be checked. Re-run this job."
    else
      echo "::warning::PR #$num ($branch) is closed ($state) and its head is gone; skipped."
    fi
  done
  cmd_cross "$base" "${targets[@]}" || fail=1
  return "$fail"
}

case "${1:-}" in
  tree) shift; cmd_tree "$@" ;;
  cross) shift; cmd_cross "$@" ;;
  open-prs) shift; cmd_open_prs "$@" ;;
  *) echo "usage: $0 tree [DIR] | cross BASE LABEL REF... | open-prs BASE" >&2; exit 2 ;;
esac
