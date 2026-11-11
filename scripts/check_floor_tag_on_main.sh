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
set -uo pipefail

file="${1:-priv/release_floor}"
floor=$(tr -d '[:space:]' 2>/dev/null <"$file")
[ -n "$floor" ] || { echo "::error::rollback floor: ${file} is missing or empty"; exit 1; }

status=""
for _ in 1 2 3; do
  status=$(gh api "repos/${GH_REPO:?GH_REPO required}/compare/refs/tags/${floor}...main" -q .status 2>/dev/null) && break
  status=""
  sleep "${FLOOR_RETRY_SLEEP:-2}"
done

case "$status" in
  ahead | identical) echo "rollback floor: ${floor} exists and main descends from it: OK" ;;
  "") echo "::error::rollback floor: tag ${floor} does not exist, or the GitHub API is unreachable. Cut the tag before naming it in ${file}."; exit 1 ;;
  *) echo "::error::rollback floor: tag ${floor} is not on main (${status}): every deploy would be refused"; exit 1 ;;
esac
