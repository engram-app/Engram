#!/usr/bin/env bash
# scripts/generate_schema_impact_notes.sh
#
# Emit a SCHEMA-IMPACT markdown block for a release range when any merged
# PR in that range carries a phase/* label. Empty output (and exit 0) means
# no schema impact — caller should skip prepending anything.
#
# Usage:
#   generate_schema_impact_notes.sh <base-sha> <head-sha>
#
# Test mode:
#   GH_OUTPUT_OVERRIDE=<json>   — pre-canned PR list (skip gh call)
#   IRREVERSIBLE_OVERRIDE=true|false — skip git-grep for # rollback-irreversible
#   MERGED_PR_NUMBERS_OVERRIDE=<space-separated PR numbers> — skip git log range walk
set -euo pipefail

BASE_SHA="${1:?base sha required}"
HEAD_SHA="${2:?head sha required}"

# Resolve PR list. Live mode uses `gh search`; test mode uses override.
if [ -n "${GH_OUTPUT_OVERRIDE:-}" ]; then
  prs="$GH_OUTPUT_OVERRIDE"
else
  # Capture gh output and exit separately. A gh failure (auth, network,
  # rate limit) silently dropping the phase-PR list would skip the
  # SCHEMA-IMPACT block for a release that actually changes the schema —
  # defeating the entire feature. Surface gh failures via ::error:: so CI
  # fails fast instead of producing a misleading release page.
  # --sort updated --order desc: the range filter below is now an
  # INTERSECTION with git log, so a phase-labeled PR missing from this
  # result silently drops the whole SCHEMA-IMPACT block (git log has no
  # way to independently notice a PR that gh search failed to return).
  # `--limit 500` only stays safe if this call is guaranteed newest-first;
  # make that explicit rather than relying on gh's default sort.
  if ! prs=$(gh search prs --repo "${GITHUB_REPOSITORY:-engram-app/Engram}" \
          --merged \
          --base main \
          --sort updated --order desc \
          --json number,labels,title \
          --limit 500 2>&1); then
    echo "::error::generate_schema_impact_notes: gh search prs failed — cannot determine phase-labeled PRs in release range. Output: $prs" >&2
    exit 1
  fi
fi

# Filter to PRs carrying any phase/* label.
phase_prs=$(echo "$prs" | jq '[.[] | select(.labels[]?.name | startswith("phase/"))]')

# Empty? Nothing to emit — caller skips the block entirely. Also skips the
# range resolution below, which needs a real commit range.
if [ "$(echo "$phase_prs" | jq 'length')" -eq 0 ]; then
  exit 0
fi

# `gh search prs` has no BASE_SHA..HEAD_SHA range filter — it just returns
# the most recently merged PRs repo-wide. Left unfiltered, every release's
# SCHEMA-IMPACT block accumulates the FULL history of phase-labeled PRs
# (including ones already shipped in prior releases), so every release
# claims a DB migration forever. Restrict to PRs whose squash-merge commit
# ("<title> (#NNNN)") actually lands in this release's range.
if [ -n "${MERGED_PR_NUMBERS_OVERRIDE:-}" ]; then
  merged_numbers="$MERGED_PR_NUMBERS_OVERRIDE"
else
  if ! merged_numbers=$(git log --pretty=%s "$BASE_SHA..$HEAD_SHA" 2>&1); then
    echo "::error::generate_schema_impact_notes: git log $BASE_SHA..$HEAD_SHA failed — cannot resolve which PRs are actually in this release. Output: $merged_numbers" >&2
    exit 1
  fi
  merged_numbers=$(printf '%s\n' "$merged_numbers" | grep -oP '\(#\K[0-9]+(?=\)$)' || true)
fi

numbers_json=$(printf '%s\n' $merged_numbers | jq -R 'select(length > 0) | tonumber' | jq -s '.')
phase_prs=$(echo "$phase_prs" | jq --argjson nums "$numbers_json" \
  '[.[] | select(.number as $n | $nums | index($n) != null)]')

# Range filter may have zeroed out every PR (all were outside this release).
if [ "$(echo "$phase_prs" | jq 'length')" -eq 0 ]; then
  exit 0
fi

# Detect any irreversible migration in the range. Test override wins;
# else grep the migration files changed between BASE and HEAD for the marker.
if [ -n "${IRREVERSIBLE_OVERRIDE:-}" ]; then
  irreversible="$IRREVERSIBLE_OVERRIDE"
else
  irreversible=false
  if git diff --name-only "$BASE_SHA...$HEAD_SHA" -- 'priv/repo/migrations/*.exs' 2>/dev/null \
     | xargs -r grep -l '# rollback-irreversible' >/dev/null 2>&1; then
    irreversible=true
  fi
fi

# Emit the SCHEMA-IMPACT block.
{
  echo "## SCHEMA-IMPACT"
  echo ""
  echo "This release modifies the database schema. **Take a database backup before upgrading.**"
  echo ""
  echo "### Upgrade procedure (self-host)"
  echo ""
  echo '```bash'
  echo "docker compose down"
  echo "docker compose pull"
  echo "docker compose up -d"
  echo "# The container's entrypoint runs migrations before Phoenix boots."
  echo '```'
  echo ""
  echo "### Schema-impacting PRs in this release"
  echo ""
  echo "$phase_prs" | jq -r '.[] | "- #\(.number) (`" + ([.labels[] | select(.name | startswith("phase/")) | .name] | join(", ")) + "`) — \(.title)"'
  echo ""
  if [ "$irreversible" = "true" ]; then
    echo "### ⚠️ IRREVERSIBLE"
    echo ""
    echo "One or more migrations in this release are marked \`# rollback-irreversible\`."
    echo "**There is no automatic rollback path.** Restore from a database backup taken before the upgrade if you need to revert."
  else
    echo "### Rollback (optional)"
    echo ""
    echo "If you need to revert to the previous release, run from inside the container:"
    echo '```bash'
    echo "bin/engram eval 'Engram.Release.rollback(Engram.Repo, <previous-version>)'"
    echo '```'
    echo ""
    echo "Then pin the previous image tag in your compose file."
  fi
}
