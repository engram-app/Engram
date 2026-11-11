#!/usr/bin/env bash
# test/scripts/check_floor_tag_on_main_test.sh
#
# check_floor_tag_on_main.sh passes only a floor tag main descends from; a
# missing tag, an off-main tag, an empty file and an API outage all fail. A
# persistent 404 fails, a transient error is retried away.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/check_floor_tag_on_main.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake gh: compare by floor tag. FAKE_FLAKY=<n> fails the first n calls.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_FLAKY:-}" ]; then
  n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) >"$FAKE_COUNT"
  [ "$n" -lt "$FAKE_FLAKY" ] && { echo '{"message":"Server Error"}'; exit 1; }
fi
case "$2" in
  */compare/refs/tags/release-v1.0.0...main) echo ahead ;;
  */compare/refs/tags/release-v1.1.0...main) echo identical ;;
  */compare/refs/tags/release-v0.9.0...main) echo diverged ;;
  */compare/refs/tags/release-v2.0.0...main) echo behind ;;
  *) echo '{"message":"Not Found"}'; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_REPO=o/r FLOOR_RETRY_SLEEP=0 FAKE_COUNT="$TMP/count"

check() { printf '%s\n' "$1" >"$TMP/floor"; bash "$SCRIPT" "$TMP/floor" >"$TMP/out" 2>&1; }

check release-v1.0.0 || fail "a tag behind main failed: $(cat "$TMP/out")"
check release-v1.1.0 || fail "main's own tag failed: $(cat "$TMP/out")"

! check release-v9.9.9 || fail "a tag that does not exist passed"
grep -q "::error::.*release-v9.9.9" "$TMP/out" || fail "no reason given: $(cat "$TMP/out")"
! check release-v0.9.0 || fail "an off-main tag passed"
grep -q "::error::.*not on main" "$TMP/out" || fail "no off-main reason: $(cat "$TMP/out")"
! check release-v2.0.0 || fail "a tag ahead of main passed"
! check "" || fail "an empty floor passed"
! bash "$SCRIPT" "$TMP/absent" >/dev/null 2>&1 || fail "a missing file passed"

FAKE_FLAKY=2 check release-v1.0.0 || fail "a transient error was not retried: $(cat "$TMP/out")"
rm -f "$TMP/count"
! FAKE_FLAKY=9 check release-v1.0.0 || fail "an API outage passed"

echo "check_floor_tag_on_main: all cases passed"
