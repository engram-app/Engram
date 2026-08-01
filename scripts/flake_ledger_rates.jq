# Trailing-14-night flake rate per suite, computed from the append-only ledger
# JSONL. Invoke with `jq -s -f` (the test), or `jq -s "$(cat ...)"` (the
# ledger-append job, which reads this into a var before switching to the
# ci-ledger orphan branch where scripts/ doesn't exist). Dedups on
# (workflow_run_id, suite) FIRST so a
# manual re-run of a scheduled night can't double-count, then windows to the
# most-recent 14 nights per suite. Emits one compact object per suite:
#   {suite, red, n, pct}
# Consumed twice by the ledger-append job (verify.yml): the step-summary table
# and the flaky-suite auto-alert gate — one source of truth for "how flaky".
unique_by([.workflow_run_id, .suite])
| group_by(.suite)[]
| (sort_by(.date) | .[-14:]) as $recent
| ($recent | length) as $n
| ([$recent[] | select(.result == "failure")] | length) as $red
| { suite: .[0].suite,
    red: $red,
    n: $n,
    pct: (if $n > 0 then (($red * 100 / $n) | floor) else 0 end) }
