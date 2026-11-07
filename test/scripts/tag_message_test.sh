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

# Fake gh: release-v1 is annotated (tag object t1), release-v2 lightweight,
# anything else 404s.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  */git/ref/tags/release-v1) echo "tag t1" ;;
  */git/ref/tags/release-v2) echo "commit c2" ;;
  */git/tags/t1) printf '[allow-below-floor] incident: test\n' ;;
  *) echo '{"message":"Not Found"}'; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_REPO=o/r

[ "$(bash "$SCRIPT" release-v1)" = "[allow-below-floor] incident: test" ] || fail "annotated message not printed"
[ -z "$(bash "$SCRIPT" release-v2)" ] || fail "a lightweight tag printed a message"
out=$(bash "$SCRIPT" release-v3) || fail "an API error exited non-zero"
[ -z "$out" ] || fail "an API error printed: $out"

echo "tag_message: all cases passed"
