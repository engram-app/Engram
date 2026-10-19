#!/usr/bin/env bash
# scripts/deployable_paths.sh <ghcr-image>
#
# Print deployable paths changed since the nearest first-parent ancestor
# that has a published `<image>:<sha7>`. Empty output = the image bytes are
# unchanged since the last build.
#
# Diffing HEAD~1 alone strands changes: if a deployable merge's CI dies
# before the image build, the next CI-only merge sees an empty HEAD~1 diff
# and skips the build, so staging never gets the deployable change.
#
# Path set comes from $DEPLOYABLE_PATHS (verify.yml's workflow env).
# Requires a prior `docker login` and a full-depth checkout.
set -euo pipefail

image="$1"
read -ra paths <<<"${DEPLOYABLE_PATHS:?DEPLOYABLE_PATHS must be set}"

# ponytail: bounded walk, 30 merges back. Past that, fall back to HEAD~1.
base=HEAD~1
for sha in $(git rev-list --first-parent --max-count=30 HEAD~1 2>/dev/null); do
  if docker manifest inspect "${image}:${sha::7}" >/dev/null 2>&1; then
    base=$sha
    break
  fi
done

git diff --name-only "$base" HEAD -- "${paths[@]}"
