#!/usr/bin/env bash
# scripts/discord_alert.sh <content>
#
# Posts <content> to the Discord webhook in $WEBHOOK. Always exits 0: it runs
# in failure steps, where an alert that cannot be sent must not change the
# job's result. No webhook configured is a skip, a failed post a ::warning::.
set -uo pipefail

content="${1:?content required}"
[ -n "${WEBHOOK:-}" ] || { echo "No alerts webhook configured, skipping."; exit 0; }
# flags:4 = SUPPRESS_EMBEDS. Discord auto-embeds every URL, so messages
# rendered as a stack of preview cards. Links stay clickable without them.
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -H 'User-Agent: engram-ci/1.0 (+https://github.com/engram-app/Engram)' \
  --max-time 10 \
  --data "$(jq -nc --arg c "$content" --arg u 'Engram CI' '{content:$c,username:$u,flags:4}')" \
  "$WEBHOOK") || code="000"
case "$code" in
  2*) echo "Alert sent ($code)" ;;
  *) echo "::warning::Discord alert failed (HTTP $code)" ;;
esac
exit 0
