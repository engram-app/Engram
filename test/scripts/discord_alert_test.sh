#!/usr/bin/env bash
# test/scripts/discord_alert_test.sh
#
# discord_alert.sh posts its argument to $WEBHOOK with embeds suppressed, and
# always exits 0: an alert that cannot be sent must not change a job's result.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/discord_alert.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake curl: records its arguments, answers $FAKE_CODE (or fails when empty).
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_ARGS"
[ -n "${FAKE_CODE:-}" ] || exit 7
printf '%s' "$FAKE_CODE"
SH
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" CURL_ARGS="$TMP/args"

out=$(WEBHOOK=http://hook FAKE_CODE=204 bash "$SCRIPT" $'line one\nline two') || fail "a sent alert exited non-zero"
grep -q "Alert sent (204)" <<<"$out" || fail "no sent line: $out"
grep -qx "http://hook" "$TMP/args" || fail "not posted to the webhook"
payload=$(grep '^{' "$TMP/args")
[ "$(jq -r .content <<<"$payload")" = $'line one\nline two' ] || fail "content changed: $payload"
[ "$(jq -r .flags <<<"$payload")" = 4 ] || fail "embeds not suppressed: $payload"
[ "$(jq -r .username <<<"$payload")" = "Engram CI" ] || fail "wrong username: $payload"

out=$(WEBHOOK=http://hook FAKE_CODE=500 bash "$SCRIPT" x) || fail "an HTTP error exited non-zero"
grep -q "::warning::Discord alert failed (HTTP 500)" <<<"$out" || fail "an HTTP error was not loud: $out"

out=$(WEBHOOK=http://hook FAKE_CODE="" bash "$SCRIPT" x) || fail "a curl failure exited non-zero"
grep -q "::warning::Discord alert failed" <<<"$out" || fail "a curl failure was not loud: $out"

rm -f "$TMP/args"
out=$(WEBHOOK="" FAKE_CODE=204 bash "$SCRIPT" x) || fail "no webhook exited non-zero"
[ ! -e "$TMP/args" ] || fail "posted with no webhook"

echo "discord_alert: all cases passed"
