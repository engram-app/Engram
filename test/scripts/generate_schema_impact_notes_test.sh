#!/usr/bin/env bash
# test/scripts/generate_schema_impact_notes_test.sh
#
# Tests scripts/generate_schema_impact_notes.sh via env-var overrides
# (GH_OUTPUT_OVERRIDE, IRREVERSIBLE_OVERRIDE) — no `gh` binary needed.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/generate_schema_impact_notes.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Test 1: phase/expand PR present, all reversible ---
output=$(GH_OUTPUT_OVERRIDE='[{"number":100,"labels":[{"name":"phase/expand"}],"title":"Add users.timezone column"}]' \
         IRREVERSIBLE_OVERRIDE='false' \
         MERGED_PR_NUMBERS_OVERRIDE='100' \
         bash "$SCRIPT" abc123 def456)

echo "$output" | grep -q 'SCHEMA-IMPACT'           || fail "Test 1: missing SCHEMA-IMPACT header"
echo "$output" | grep -q 'phase/expand'            || fail "Test 1: missing phase label citation"
echo "$output" | grep -q '#100'                    || fail "Test 1: missing PR number"
echo "$output" | grep -q 'docker compose down'     || fail "Test 1: missing downtime procedure"
echo "$output" | grep -q 'Engram.Release.rollback' || fail "Test 1: missing rollback hint (should be present when reversible)"

# --- Test 2: no phase-labeled PRs → empty output ---
output_empty=$(GH_OUTPUT_OVERRIDE='[]' IRREVERSIBLE_OVERRIDE='false' bash "$SCRIPT" abc123 def456)
[ -z "$output_empty" ] || fail "Test 2: expected empty output when no phase PRs; got: $output_empty"

# --- Test 3: only non-phase PRs → empty output ---
output_non_phase=$(GH_OUTPUT_OVERRIDE='[{"number":50,"labels":[{"name":"bug"}],"title":"Unrelated fix"}]' \
                   IRREVERSIBLE_OVERRIDE='false' \
                   bash "$SCRIPT" abc123 def456)
[ -z "$output_non_phase" ] || fail "Test 3: expected empty output when no phase/* labels; got: $output_non_phase"

# --- Test 4: irreversible migration → rollback hint omitted, IRREVERSIBLE warning emitted ---
output_irrev=$(GH_OUTPUT_OVERRIDE='[{"number":200,"labels":[{"name":"phase/contract"}],"title":"Drop users.legacy_flag"}]' \
               IRREVERSIBLE_OVERRIDE='true' \
               MERGED_PR_NUMBERS_OVERRIDE='200' \
               bash "$SCRIPT" abc123 def456)

echo "$output_irrev" | grep -q 'Engram.Release.rollback' && \
  fail "Test 4: rollback hint should be omitted when irreversible" || true
echo "$output_irrev" | grep -qi 'IRREVERSIBLE' || fail "Test 4: missing IRREVERSIBLE marker"
echo "$output_irrev" | grep -q 'phase/contract' || fail "Test 4: missing phase/contract label citation"

# --- Test 5: multiple phase PRs, multiple labels per PR ---
output_multi=$(GH_OUTPUT_OVERRIDE='[
  {"number":100,"labels":[{"name":"phase/expand"}],"title":"Add column"},
  {"number":101,"labels":[{"name":"phase/contract"},{"name":"bug"}],"title":"Drop column"},
  {"number":102,"labels":[{"name":"feature"}],"title":"Unrelated"}
]' IRREVERSIBLE_OVERRIDE='false' MERGED_PR_NUMBERS_OVERRIDE='100 101 102' \
  bash "$SCRIPT" abc123 def456)

echo "$output_multi" | grep -q '#100' || fail "Test 5: missing #100"
echo "$output_multi" | grep -q '#101' || fail "Test 5: missing #101"
echo "$output_multi" | grep -q '#102' && fail "Test 5: should NOT include #102 (no phase label)" || true
echo "$output_multi" | grep -q 'phase/expand' || fail "Test 5: missing phase/expand"
echo "$output_multi" | grep -q 'phase/contract' || fail "Test 5: missing phase/contract"
echo "$output_multi" | grep -q '"bug"' && fail "Test 5: should NOT cite non-phase labels" || true


# --- Test 6: gh search returns a phase PR from OUTSIDE this release's range
# (e.g. already shipped in a prior release) → excluded. Regression test for
# the "every release claims a DB migration" bug: gh search prs has no range
# filter of its own, so without MERGED_PR_NUMBERS_OVERRIDE filtering, #100
# and #101 would both appear even though only #101 merged in this range.
output_range=$(GH_OUTPUT_OVERRIDE='[
  {"number":100,"labels":[{"name":"phase/expand"}],"title":"Shipped in a prior release"},
  {"number":101,"labels":[{"name":"phase/expand"}],"title":"Shipped in THIS release"}
]' IRREVERSIBLE_OVERRIDE='false' MERGED_PR_NUMBERS_OVERRIDE='101' \
   bash "$SCRIPT" abc123 def456)

echo "$output_range" | grep -q '#101' || fail "Test 6: missing #101 (in range)"
echo "$output_range" | grep -q '#100' && fail "Test 6: should NOT include #100 (outside range)" || true

# --- Test 7: phase PRs exist but none are in range → empty output ---
output_range_empty=$(GH_OUTPUT_OVERRIDE='[
  {"number":100,"labels":[{"name":"phase/expand"}],"title":"Shipped in a prior release"}
]' IRREVERSIBLE_OVERRIDE='false' MERGED_PR_NUMBERS_OVERRIDE='999' \
   bash "$SCRIPT" abc123 def456)
[ -z "$output_range_empty" ] || fail "Test 7: expected empty output when no phase PRs are in range; got: $output_range_empty"


# --- Test 8: real git-log extraction, NO MERGED_PR_NUMBERS_OVERRIDE. Tests
# 1-7 all set the override, which bypasses the actual `git log` parse —
# the one piece of new logic that carries real risk (the grep pattern, the
# `$`-anchor, squash- vs merge-commit shapes). Without this test, a change
# that silently disabled the range filter entirely would still pass every
# other test in this file. Uses a real scratch git repo so the regex runs
# against real commit subjects, not a hand-fed number list.
tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT
gc() { git -C "$tmp_repo" -c user.email=test@example.com -c user.name=test "$@"; }
git -c init.defaultBranch=main -C "$tmp_repo" init -q
gc commit -q --allow-empty -m "chore: base"
base_sha=$(git -C "$tmp_repo" rev-parse HEAD)
gc commit -q --allow-empty -m "feat: in range (#101)"
gc commit -q --allow-empty -m "chore: direct push, no PR number"
head_sha=$(git -C "$tmp_repo" rev-parse HEAD)

output_real=$(cd "$tmp_repo" && GH_OUTPUT_OVERRIDE='[
  {"number":100,"labels":[{"name":"phase/expand"}],"title":"Shipped in a prior release"},
  {"number":101,"labels":[{"name":"phase/expand"}],"title":"Shipped in THIS release"}
]' IRREVERSIBLE_OVERRIDE='false' bash "$SCRIPT" "$base_sha" "$head_sha")

echo "$output_real" | grep -q '#101' || fail "Test 8: real git-log extraction missed in-range #101"
echo "$output_real" | grep -q '#100' && fail "Test 8: real git-log extraction included out-of-range #100" || true

echo "All tests passed (8)."
