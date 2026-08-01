#!/usr/bin/env bash
# Self-check for flake_ledger_rates.jq: dedup + trailing-14 windowing + rate math.
# The gnarly part of the flaky-suite monitor; a dispatch can't cheaply exercise
# it (it drags the whole e2e matrix), so this runs the logic offline.
#   Run: bash scripts/flake_ledger_rates_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT

{
  # e2e-crdt: night 01 is the OLDEST and a failure -> must fall OUT of the
  # 14-night window. Nights 02..15 (14 kept) hold 6 failures -> 6/14 = 42%.
  echo '{"date":"2026-07-01","sha":"a","workflow_run_id":"1","suite":"e2e-crdt","result":"failure","duration_s":1}'
  for i in 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
    case $i in 04|06|08|10|12|14) r=failure ;; *) r=success ;; esac
    echo "{\"date\":\"2026-07-$i\",\"sha\":\"a\",\"workflow_run_id\":\"$i\",\"suite\":\"e2e-crdt\",\"result\":\"$r\",\"duration_s\":1}"
  done
  # Duplicate of night 15 (same run_id+suite) -> must dedup, not double-count.
  echo '{"date":"2026-07-15","sha":"a","workflow_run_id":"15","suite":"e2e-crdt","result":"success","duration_s":1}'
  # e2e-clerk: 14 green -> 0%.
  for i in 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
    echo "{\"date\":\"2026-07-$i\",\"sha\":\"a\",\"workflow_run_id\":\"c$i\",\"suite\":\"e2e-clerk\",\"result\":\"success\",\"duration_s\":1}"
  done
  # e2e-browser: small sample (3 nights, 2 red) -> rate computed; caller applies MIN_NIGHTS.
  echo '{"date":"2026-07-13","sha":"a","workflow_run_id":"b1","suite":"e2e-browser","result":"failure","duration_s":1}'
  echo '{"date":"2026-07-14","sha":"a","workflow_run_id":"b2","suite":"e2e-browser","result":"failure","duration_s":1}'
  echo '{"date":"2026-07-15","sha":"a","workflow_run_id":"b3","suite":"e2e-browser","result":"success","duration_s":1}'
} >"$fixture"

got=$(jq -s -f scripts/flake_ledger_rates.jq "$fixture" | jq -sc 'sort_by(.suite)')
want='[{"suite":"e2e-browser","red":2,"n":3,"pct":66},{"suite":"e2e-clerk","red":0,"n":14,"pct":0},{"suite":"e2e-crdt","red":6,"n":14,"pct":42}]'

if [ "$got" != "$want" ]; then
  echo "FAIL"
  echo "want: $want"
  echo "got:  $got"
  exit 1
fi
echo "PASS: flake_ledger_rates.jq dedup + trailing-14 window + rate math"
