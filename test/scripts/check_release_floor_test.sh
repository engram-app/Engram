#!/usr/bin/env bash
# test/scripts/check_release_floor_test.sh
#
# check_release_floor.sh passes a deploy at or above the floor tag, fails one
# below it (and every unresolvable input: fail closed), and passes a
# below-floor deploy only with ALLOW_BELOW_FLOOR=true, loudly.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/check_release_floor.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$TMP/repo"
git init -q "$repo"
cd "$repo"
git config user.email t@t
git config user.name t
git config commit.gpgsign false
git config tag.gpgSign false
commit() { echo "$RANDOM" >>f; git add -A; git commit -qm "$1"; git rev-parse HEAD; }

old=$(commit old)          # below the floor
floor=$(commit floor)
git tag release-v0.76.0 "$floor"
new=$(commit new)          # above the floor
git checkout -q -b side "$old"
side=$(commit side)        # branched below the floor: not a descendant
git checkout -q -

pass() { GITHUB_STEP_SUMMARY="$TMP/summary" bash "$SCRIPT" "$@" >"$TMP/out" 2>&1; }

pass release-v0.76.0 "$new" || fail "a descendant failed: $(cat "$TMP/out")"
pass release-v0.76.0 "$floor" || fail "the floor commit itself failed: $(cat "$TMP/out")"

! pass release-v0.76.0 "$old" || fail "a pre-floor commit passed"
grep -q "below the floor" "$TMP/out" || fail "no reason given: $(cat "$TMP/out")"
! pass release-v0.76.0 "$side" || fail "a commit off a pre-floor branch passed"

! pass release-v0.99.0 "$new" || fail "a missing floor tag passed"
! pass "" "$new" || fail "an empty floor passed"
! pass "v0.76.0" "$new" || fail "a malformed floor passed"
! pass release-v0.76.0 "" || fail "an empty deploy commit passed"
! pass release-v0.76.0 deadbeef || fail "an unknown deploy commit passed"

ALLOW_BELOW_FLOOR=true pass release-v0.76.0 "$old" || fail "the override did not pass"
grep -q "::warning::.*BELOW the floor" "$TMP/out" || fail "the override was not loud"
grep -q "OVERRIDDEN" "$TMP/summary" || fail "the override left no summary line"
! ALLOW_BELOW_FLOOR=true pass release-v0.99.0 "$new" || fail "the override passed a missing floor tag"

echo "check_release_floor: all cases passed"
