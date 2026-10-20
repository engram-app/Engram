# Context Doc: CI runner network and disk gotchas

_Last verified: 2026-10-20_

**Trigger:** "Checkout plugin" slow (minutes) or hung until cancelled; CI
Postgres "unhealthy" or "Wait for DB + ecto setup" fails on a `gamingpc-*`
runner; e2e-browser `Failed to sign in ... Too Many Requests`; marketing lychee
`https://sentry.io/privacy/ Connection refused`; a job ends `failure` with a
step still `in_progress` and no log; engram-infra `main` red from
`bin/assert-main-tip.sh`; plugin release-please PR red on intermediate pushes.

Runners: `runner-*`, `fastraid-*`, and `gamingpc-*` VMs (the gaming PC VMs share
one disk). All runners share one NAT IP to GitHub. Git traffic to
`github.com/engram-app/Engram*` is rewritten by system git config
(`url.<git_cdn>.insteadOf https://github.com/engram-app/Engram`) to the
`git_cdn` pull-through cache on FastRaid `:8095` (homelab `runner_vm` role).

## 1. Plugin checkout slow or hung in e2e jobs

**Symptom.** 117 "Checkout plugin" steps since 10-19: p50 3 s, p90 221 s, max
885 s. Two hung until cancelled (run 39375387565 on gamingpc-3; PR #2072 on
runner-5).

**Cause.** The step fetched
`https://x-access-token:${GH_TOKEN}@github.com/engram-app/Engram-obsidian.git`.
The embedded credentials make the URL not match the `insteadOf` prefix, so the
fetch skipped `git_cdn` and went straight to GitHub, which bandwidth-shapes the
runners' shared NAT IP (homelab `docs/runner-vm-bringup.md` gotcha 13). A
shallow fetch alone still took 78-127 s.

**Fix (PR #2074).** Plain public URL (rewrites to `git_cdn`, same as
`actions/checkout`), `--depth=1`, `GIT_HTTP_LOW_SPEED_LIMIT`/`GIT_HTTP_LOW_SPEED_TIME`
abort, 3 tries with the token URL as the last, step `timeout-minutes: 5`.
Result: 3-8 s.

**Rule.** Any git URL with embedded credentials bypasses the cache.
Engram-obsidian is public; fetch it plain.

**How found.** Step-duration distribution across recent runs via the Actions
API, then comparing the fetched URL to the runners' `insteadOf` config.

## 2. Service Postgres unhealthy on gamingpc runners

**Symptom.** storage-database run 39373741040 on gamingpc-4: Postgres ready 1 s
after the 30 s health budget. e2e-browser "Wait for DB + ecto setup" failed 3
times on gamingpc the same way.

**Cause.** `initdb` 23 s plus shutdown checkpoint 6 s on the gaming PC VMs'
shared disk. fsync-bound, not CPU.

**Fix (PR #2071).** `--tmpfs /var/lib/postgresql` (service `options:`) or
compose `tmpfs:` for every CI Postgres. `unit-tests` already had it. Healthy in
2.5 s after. Qdrant got the same in #2066 (payload index builds took 0.1-15 s
per fsync).

**How found.** Container startup log timestamps (`initdb` and checkpoint
durations) against the health-check budget.

## 3. Clerk test instance 429

**Symptom.** e2e-browser `Failed to sign in ... Too Many Requests`. 3 of the
last 10 e2e-browser failures.

**Cause.** Rate limit on the shared Clerk test instance.

**Fix (PR #2077).** `clerkSignIn` in `frontend/e2e/clerk-helpers.ts` retries a
429 with backoff, 30 s budget.

**How found.** Grouping the last 10 e2e-browser failures by error message.

## 4. Marketing lychee: sentry.io connection refused

**Symptom.** `https://sentry.io/privacy/ Connection refused` on every
`gamingpc-*` runner (4 of 4), never on `runner-*` or `fastraid-*`.

**Cause.** lychee's connection path on those runners. `sentry-cli` uploads from
the same runners succeed. Likely IPv6 without fallback; unverified.

**Fix (engram-marketing PR #252).** Exclude `sentry.io` from lychee.

**How found.** Correlating lychee failures with runner name.

## 5. Runner lost mid-job

**Symptom.** 2026-10-20 09:37Z: e2e-clerk (gamingpc-4) and huge-notes
(gamingpc-5) both ended `failure` within 13 s of each other, each with a step
still `in_progress` and no log uploaded (logs API returns `BlobNotFound`/404).
None in the previous two days.

**Cause.** Host-level event on the gaming PC, not a test failure.

**Fix.** None needed. Identify by a completed job with a step status
`in_progress`; re-running is correct for this case only.

**How found.** Jobs API step statuses plus the missing log blob, two runners on
the same host failing in the same window.

## 6. engram-infra main red from assert-main-tip

**Symptom.** engram-infra `main` red from `bin/assert-main-tip.sh`. 2 of 5
recent infra CI failures.

**Cause.** A second merge lands while the first run is still planning or
waiting. The older run correctly refuses to apply a non-tip commit
(engram-infra#1030), but the job reports failure.

**Fix.** Not changed; it guards prod applies. Proposal: skip (not fail) when
not tip, still fail closed when the tip is unreadable.

**How found.** Classifying recent engram-infra CI failures by failing step.

## 7. Plugin release-please PR reds

**Symptom.** Red checks on the plugin release-please PR.

**Cause.** Intermediate force-push states: manifest bumped before
`versions.json`; checkout `not our ref` on superseded SHAs. The final head is
green.

**Fix.** None. Not a blocker; judge the PR by its final head.

**How found.** Comparing failing run SHAs against the PR's current head.
