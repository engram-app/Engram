#!/usr/bin/env bash
# test/scripts/check_migration_versions_test.sh
#
# priv/repo/check_migration_versions.sh must fail on a duplicate migration
# version, in one tree and across main + open PR heads, and pass otherwise.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../priv/repo/check_migration_versions.sh"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mig-versions-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REAL_GIT=$(command -v git)

fail() { echo "FAIL: $*" >&2; exit 1; }
mig() { mkdir -p "$(dirname "$1")" && echo "defmodule M${2:-} do end" > "$1"; }

# ── tree ──
mig "$TMP/dup/20261107140000_a.exs"
mig "$TMP/dup/20261107140000_b.exs"
mig "$TMP/dup/20261107150000_c.exs"
out=$(bash "$SCRIPT" tree "$TMP/dup") && fail "tree passed with a duplicate version"
grep -q '20261107140000: 20261107140000_a.exs 20261107140000_b.exs' <<<"$out" ||
  fail "tree did not name the duplicate: $out"

# Ecto compares versions as integers: 01 and 1 are the same migration.
mig "$TMP/int/01_a.exs"
mig "$TMP/int/1_b.exs"
bash "$SCRIPT" tree "$TMP/int" >/dev/null && fail "tree passed on 01_ vs 1_ (same integer version)"

mig "$TMP/ok/20261107140000_a.exs"
mig "$TMP/ok/20261107150000_c.exs"
bash "$SCRIPT" tree "$TMP/ok" >/dev/null || fail "tree failed on unique versions"

# ── open-prs / cross ── a bare origin standing in for GitHub, with
# refs/pull/<n>/head refs like GitHub keeps them.
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git config user.email t@t && git config user.name t && git config commit.gpgsign false
D=priv/repo/migrations
mig "$D/20261101000000_base.exs" Base
git add -A && git commit -qm base && git branch -M main && git push -q origin main

branch() { # branch NAME PR_NUMBER FILE...  (PR_NUMBER "-" = no pull ref)
  local name=$1 pr=$2; shift 2
  git switch -q -c "$name" main
  for f in "$@"; do mig "$D/$f" "$name"; done
  git add -A && git commit -qm "$name" && git push -q origin HEAD
  [ "$pr" = - ] || git push -q origin "HEAD:refs/pull/$pr/head"
}
branch other   1 20261107140000_other.exs     # different migration, same version
branch stacked 2 20261107140000_mine.exs      # same file: a stacked PR, not a clash
branch forked  4 20261107190000_fork.exs      # fork PR: checked via refs/pull
branch vanish  8 20261107200000_vanish.exs    # closed; fetch fails (shim below)
# Our own PR's pull ref is stale with an OLD name for the version; it must
# be skipped, not flagged against ourselves.
branch selfold 5 20261107140000_old_name.exs
branch basedup 11 20261101000000_dup.exs      # reuses the BASE version
branch mine    - 20261107140000_mine.exs

# Fake gh: open-PR list rows (what --jq yields) and per-PR state.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") cat "$GH_PRS" ;;
  "pr view") [ "$3" = 12 ] && { echo "HTTP 502" >&2; exit 1; }
    awk -v n="$3" '$1 == n { print $2 }' "$GH_STATES" ;;
  *) exit 2 ;;
esac
SH
# git shim: a fetch naming PR #8's ref fails, as when its branch is deleted
# between listing the PRs and fetching them.
cat > "$TMP/bin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = fetch ] && [[ " \$* " == *vanish* || " \$* " == *refs/pull/8/* ]]; then
  echo "fatal: couldn't find remote ref" >&2; exit 128
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$TMP/bin/gh" "$TMP/bin/git"
printf '7\tOPEN\n8\tCLOSED\n10\tMERGED\n' > "$TMP/states"
export PATH="$TMP/bin:$PATH" GH_STATES="$TMP/states" PR_FETCH_URL="$TMP/origin.git"
run() { # run SELF_BRANCH PR_ROWS...
  local self=$1; shift
  printf '%b\n' "$@" > "$TMP/prs"
  GH_PRS="$TMP/prs" GITHUB_HEAD_REF=$self bash "$SCRIPT" open-prs main 2>&1
}

out=$(run mine '1\tother\tfalse' '2\tstacked\tfalse' '4\tfork-x\ttrue' '5\tmine\tfalse' '8\tvanish\tfalse') &&
  fail "open-prs passed with a colliding open PR"
grep -q 'version 20261107140000 is also used by PR #1' <<<"$out" || fail "collision not named: $out"
grep -q 'PR #2 ' <<<"$out" && fail "stacked PR (same file) flagged: $out"
grep -q 'PR #5' <<<"$out" && fail "own PR not skipped: $out"
grep -q 'PR #4' <<<"$out" && fail "fork PR not checked via its pull ref: $out"
grep -q '::warning::PR #8 (vanish) is closed' <<<"$out" || fail "closed PR with vanished ref did not warn: $out"

# A branch that only ADDS a version through a rename (git status R) is checked.
git switch -q -c renamer main
git mv "$D/20261101000000_base.exs" "$D/20261107140000_renamed.exs"
git commit -qm rename
out=$(run renamer '1\tother\tfalse') && fail "renamed-in migration not cross-checked: $out"
grep -q 'also used by PR #1' <<<"$out" || fail "renamed-in collision not named: $out"

# EDITING an existing migration is not adding one: only added files are
# cross-checked, even when another PR reuses the edited file's version.
git switch -q -c editor main
echo "# edited" >> "$D/20261101000000_base.exs" && git commit -qam edit
out=$(run editor '11\tbasedup\tfalse') || fail "edited (not added) migration flagged: $out"

# Clean branch: renumbered.
git switch -q -c clean main && mig "$D/20261107180000_clean.exs" && git add -A && git commit -qm clean

# An OPEN PR whose head cannot be fetched (lagging cache, GitHub hiccup) fails.
out=$(run clean '1\tother\tfalse' '7\tlagging\tfalse') && fail "unfetchable open PR passed: $out"
grep -q '::error::PR #7 (lagging) is open but its head could not be fetched' <<<"$out" ||
  fail "unfetchable open PR not named: $out"

# Closed PRs whose refs vanished only warn; names are annotation-escaped.
out=$(run clean '1\tother\tfalse' '8\tvanish\tfalse' '10\tx%y\tfalse') ||
  fail "closed PRs with vanished refs failed the gate: $out"
grep -q '::warning::PR #10 (x%25y) is closed' <<<"$out" || fail "branch name not escaped: $out"

# A gh failure on the state lookup is a visible error, not a silent abort.
out=$(run clean '12\tghfail\tfalse') && fail "gh pr view failure passed: $out"
grep -q '::error::Could not read the state of PR #12' <<<"$out" || fail "gh pr view failure not reported: $out"

# A PR list that hits the cap may be truncated: fail rather than skip PRs.
out=$(PR_LIST_LIMIT=2 run clean '1\tother\tfalse' '2\tstacked\tfalse') && fail "truncated PR list passed: $out"
grep -q '::error::gh pr list returned 2 PRs' <<<"$out" || fail "truncated PR list not reported: $out"

# Same version already on main under another name.
git switch -q main && mig "$D/20261107140000_main.exs" Main && git add -A && git commit -qm m && git push -q origin main
git switch -q mine
out=$(bash "$SCRIPT" cross "$(git merge-base origin/main HEAD)" main origin/main 2>&1) &&
  fail "cross passed with a version already on main"
grep -q 'also used by main' <<<"$out" || fail "main collision not named: $out"

echo "OK - check_migration_versions.sh"
