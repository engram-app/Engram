#!/usr/bin/env bash
# scripts/tag_message.sh <tag>
#
# Prints the message of an ANNOTATED tag in $GH_REPO, read through the API
# (no dependence on local fetch depth), or nothing. A lightweight tag (the
# normal release recipe) has no message, and any API error prints nothing:
# callers look for an override marker in it ([skip-release-e2e],
# [allow-below-floor]), so an empty message is the safe, gated default.
# The one copy of this lookup; deploy-prod.yml's override steps call it.
set -uo pipefail

tag="${1:?tag required}"
ref=$(gh api "repos/${GH_REPO:?GH_REPO required}/git/ref/tags/${tag}" -q '.object.type + " " + .object.sha' 2>/dev/null) || exit 0
read -r obj_type obj_sha <<<"$ref"
[ "${obj_type:-}" = "tag" ] && [ -n "${obj_sha:-}" ] || exit 0
# A lightweight tag made FROM an annotated one points at the same tag object:
# the message belongs only to the tag that object names.
out=$(gh api "repos/${GH_REPO}/git/tags/${obj_sha}" -q '.tag + "\n" + .message' 2>/dev/null) || exit 0
{
  read -r name
  if [ "$name" = "$tag" ]; then
    cat
  else
    # stdout stays empty (gated); say why an override marker was ignored.
    echo "::notice::tag ${tag} points at the tag object of ${name}: its message is not read, so no override applies. Create the tag under its own name (git tag -a ${tag} ...)." >&2
  fi
} <<<"$out"
