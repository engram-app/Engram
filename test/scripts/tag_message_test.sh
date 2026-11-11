#!/usr/bin/env bash
# test/scripts/tag_message_test.sh
#
# tag_message.sh prints an annotated tag's message, and nothing (exit 0) for
# a lightweight tag or any API error: the override markers deploy-prod.yml
# looks for must never appear by accident.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/tag_message.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake gh: answers real JSON through the caller's -q filter (jq, the language
# gh -q takes). release-v1 is annotated (tag object t1), release-v2 lightweight,
# release-v3 a lightweight tag made FROM release-v1 (its ref holds the same tag
# object), release-v5 annotated with an empty message; anything else 404s.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  */git/ref/tags/release-v1 | */git/ref/tags/release-v3) body='{"object":{"type":"tag","sha":"t1"}}' ;;
  */git/ref/tags/release-v2) body='{"object":{"type":"commit","sha":"c2"}}' ;;
  */git/ref/tags/release-v5) body='{"object":{"type":"tag","sha":"t5"}}' ;;
  */git/tags/t1) body='{"tag":"release-v1","message":"[allow-below-floor] incident: test\nsecond line\n"}' ;;
  */git/tags/t5) body='{"tag":"release-v5","message":""}' ;;
  *) echo '{"message":"Not Found"}'; exit 1 ;;
esac
jq -j "$4" <<<"$body"
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_REPO=o/r

[ "$(bash "$SCRIPT" release-v1)" = $'[allow-below-floor] incident: test\nsecond line' ] || fail "annotated message not printed"
[ -z "$(bash "$SCRIPT" release-v2)" ] || fail "a lightweight tag printed a message"
out=$(bash "$SCRIPT" release-v3) || fail "a tag made from an annotated tag exited non-zero"
[ -z "$out" ] || fail "a lightweight tag inherited an annotated tag's message: $out"
out=$(bash "$SCRIPT" release-v5) || fail "an empty message exited non-zero"
[ -z "$out" ] || fail "an empty message printed: $out"
out=$(bash "$SCRIPT" release-v4) || fail "an API error exited non-zero"
[ -z "$out" ] || fail "an API error printed: $out"

echo "tag_message: all cases passed"
