#!/usr/bin/env bash
# test/scripts/deploy_prod_floor_wiring_test.sh
#
# The script tests cannot see how the workflows call them. This pins the
# wiring: the floor gate reads MAIN's floor and judges the tagged commit, a
# red gate alerts, the deploy waits on the gate, and CI checks the floor tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)/../.."
DEPLOY="$ROOT/.github/workflows/deploy-prod.yml"
VERIFY="$ROOT/.github/workflows/verify.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

job() { awk -v j="  $2:" '$0 == j { f = 1; next } f && /^  [a-z0-9-]+:$/ { exit } f' "$1"; }

gate=$(job "$DEPLOY" release-floor-gate)
[ -n "$gate" ] || fail "no release-floor-gate job"
grep -q 'fetch-depth: 0' <<<"$gate" || fail "the gate does not fetch history and tags"
grep -q 'git show origin/main:priv/release_floor' <<<"$gate" || fail "the gate does not read main's floor"
grep -q 'check_release_floor.sh "$floor" "$GITHUB_SHA"' <<<"$gate" || fail "the gate does not judge the tagged commit"
grep -q 'if: failure()' <<<"$gate" || fail "a red gate has no failure step"
grep -q 'bash scripts/discord_alert.sh' <<<"$gate" || fail "a red gate does not alert"
grep -q 'DISCORD_ALERTS_WEBHOOK_URL' <<<"$gate" || fail "the gate's alert has no webhook"

e2e=$(job "$DEPLOY" release-e2e-gate)
grep -q 'needs: release-floor-gate' <<<"$e2e" || fail "the deploy does not wait on the floor gate"

static=$(job "$VERIFY" static-checks)
grep -q 'bash scripts/check_floor_tag_on_main.sh' <<<"$static" || fail "CI does not check the floor tag"

echo "deploy_prod_floor_wiring: all cases passed"
