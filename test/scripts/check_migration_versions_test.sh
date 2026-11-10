#!/usr/bin/env bash
# test/scripts/check_migration_versions_test.sh
#
# priv/repo/check_migration_versions.sh must fail on a duplicate migration
# version, in one tree and across main + open PR branches, and pass otherwise.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../priv/repo/check_migration_versions.sh"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mig-versions-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
mig() { mkdir -p "$(dirname "$1")" && echo "defmodule M do end" > "$1"; }

# ── tree ──
mig "$TMP/dup/20261107140000_a.exs"
mig "$TMP/dup/20261107140000_b.exs"
mig "$TMP/dup/20261107150000_c.exs"
out=$(bash "$SCRIPT" tree "$TMP/dup") && fail "tree passed with a duplicate version"
grep -q '20261107140000: 20261107140000_a.exs 20261107140000_b.exs' <<<"$out" ||
  fail "tree did not name the duplicate: $out"

mig "$TMP/ok/20261107140000_a.exs"
mig "$TMP/ok/20261107150000_c.exs"
bash "$SCRIPT" tree "$TMP/ok" >/dev/null || fail "tree failed on unique versions"

# ── open-prs / cross ── a bare origin with main + three PR branches.
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git config user.email t@t && git config user.name t && git config commit.gpgsign false
D=priv/repo/migrations
mig "$D/20261101000000_base.exs"
git add -A && git commit -qm base && git branch -M main && git push -q origin main

branch() { # branch NAME FILE...
  git switch -q -c "$1" main; shift
  for f in "$@"; do mig "$D/$f"; done
  git add -A && git commit -qm "$*" && git push -q origin HEAD
}
branch other   20261107140000_other.exs     # different migration, same version
branch stacked 20261107140000_mine.exs      # same file: a stacked PR, not a clash
branch gone    20261107140000_gone.exs
git push -q origin --delete gone
branch mine    20261107140000_mine.exs

# Fake gh: returns the open-PR list as tab-separated rows (what --jq yields).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '1\tother\tfalse\n2\tstacked\tfalse\n3\tgone\tfalse\n4\tfork-x\ttrue\n5\tmine\tfalse\n'
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GITHUB_HEAD_REF=mine

out=$(bash "$SCRIPT" open-prs main 2>&1) && fail "open-prs passed with a colliding open PR"
grep -q 'version 20261107140000 is also used by PR #1' <<<"$out" || fail "collision not named: $out"
grep -q 'PR #2' <<<"$out" && fail "stacked PR (same file) flagged: $out"
grep -q '::warning::PR #3' <<<"$out" || fail "vanished branch did not warn: $out"
grep -q '::warning::PR #4' <<<"$out" || fail "fork did not warn: $out"

# Same version already on main under another name.
git switch -q main && mig "$D/20261107140000_main.exs" && git add -A && git commit -qm m && git push -q origin main
git switch -q mine
out=$(bash "$SCRIPT" cross "$(git merge-base origin/main HEAD)" main origin/main 2>&1) &&
  fail "cross passed with a version already on main"
grep -q 'also used by main' <<<"$out" || fail "main collision not named: $out"

# No collision: renumbered.
git switch -q -c clean "$(git merge-base origin/main HEAD)" && mig "$D/20261107180000_clean.exs"
git add -A && git commit -qm clean
GITHUB_HEAD_REF=clean bash "$SCRIPT" open-prs main >/dev/null 2>&1 || fail "open-prs failed on a unique version"

echo "OK - check_migration_versions.sh"
