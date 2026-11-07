#!/usr/bin/env bash
# scripts/check_release_floor.sh <floor_tag> <deploy_sha>
#
# Fails unless <deploy_sha> is the rollback floor's commit or a descendant of
# it (`git merge-base --is-ancestor`). <floor_tag> is the content of main's
# priv/release_floor (`Engram.Release.Floor`), never the deployed commit's:
# an old commit carries an older floor. Fails closed: an empty or malformed
# floor, a floor tag or deploy commit git cannot resolve, all fail.
#
# ALLOW_BELOW_FLOOR=true passes a below-floor deploy with a loud warning (the
# incident override, from an `[allow-below-floor]` annotated tag message).
# Needs the repo's tags and history (checkout with fetch-depth: 0).
set -euo pipefail

floor="${1:-}"
sha="${2:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() {
  echo "::error::rollback floor: $*"
  echo "- Rollback floor check FAILED: $*" >>"$summary"
  exit 1
}

[[ "$floor" =~ ^release-v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "floor '${floor}' is not a release-vX.Y.Z tag"
floor_sha=$(git rev-parse --verify --quiet "refs/tags/${floor}^{commit}") ||
  fail "floor tag ${floor} not found"
deploy=$(git rev-parse --verify --quiet "${sha}^{commit}") ||
  fail "deploy commit '${sha}' not found"

if git merge-base --is-ancestor "$floor_sha" "$deploy"; then
  echo "rollback floor: ${deploy} descends from ${floor} (${floor_sha}): OK"
  echo "- Rollback floor ${floor}: OK" >>"$summary"
  exit 0
fi

if [ "${ALLOW_BELOW_FLOOR:-}" = "true" ]; then
  who="${GITHUB_ACTOR:-unknown}"
  echo "::warning::rollback floor: ${who} is deploying ${deploy}, BELOW the floor ${floor}, via [allow-below-floor]. Releases below the floor cannot read data newer releases wrote."
  echo "- **Rollback floor OVERRIDDEN** by ${who}: ${deploy} is below ${floor}" >>"$summary"
  exit 0
fi

fail "${deploy} is below the floor ${floor}: it does not descend from ${floor_sha}"
