#!/usr/bin/env bash
# scripts/check_floor_tag_on_main.sh [floor_file]
#
# Fails unless the tag named in priv/release_floor exists and main descends
# from it. Without this a typo or a not-yet-cut tag merges green, and then
# scripts/check_release_floor.sh refuses every deploy, overrides included.
#
# Asks the GitHub API (needs $GH_REPO), so it does not depend on the checkout's
# depth or fetched tags. `refs/tags/` so a branch of the same name cannot pass.
# Fails closed; a transient API error is retried.
#
# Also fails unless the floor tag contains every commit listed in
# priv/release_floor_contains (one "<sha> <why>" per line): code that needs
# the floor at a release (the S5 write stop needs the moved-folder feed,
# Engram#2523) names the merge commit that release must carry, so a floor
# raised to the wrong tag cannot pass.
set -uo pipefail

file="${1:-priv/release_floor}"
contains="${2:-priv/release_floor_contains}"
floor=$(tr -d '[:space:]' 2>/dev/null <"$file")
[ -n "$floor" ] || { echo "::error::rollback floor: ${file} is missing or empty"; exit 1; }

# The compare status of base...head, retried; "" when it never answered.
compare() {
  local out=""
  for _ in 1 2 3; do
    out=$(gh api "repos/${GH_REPO:?GH_REPO required}/compare/$1...$2" -q .status 2>/dev/null) && break
    out=""
    sleep "${FLOOR_RETRY_SLEEP:-2}"
  done
  echo "$out"
}

status=$(compare "refs/tags/${floor}" main)

case "$status" in
  ahead | identical) echo "rollback floor: ${floor} exists and main descends from it: OK" ;;
  "") echo "::error::rollback floor: tag ${floor} does not exist, or the GitHub API is unreachable. Cut the tag before naming it in ${file}."; exit 1 ;;
  *) echo "::error::rollback floor: tag ${floor} is not on main (${status}): every deploy would be refused"; exit 1 ;;
esac

[ -f "$contains" ] || exit 0
while read -r sha why; do
  [ -n "$sha" ] || continue
  case "${sha}" in "#"*) continue ;; esac
  # The commit behind (or at) the tag: the tag contains it.
  case "$(compare "refs/tags/${floor}" "$sha")" in
    behind | identical) echo "rollback floor: ${floor} contains ${sha} (${why}): OK" ;;
    *) echo "::error::rollback floor: ${floor} does not contain ${sha} (${why}), or the commit is unknown"; exit 1 ;;
  esac
done <"$contains"
