# Context Doc: CI runner network and disk gotchas

_Last verified: 2026-11-07_

**Trigger:** "Checkout plugin" slow (minutes) or hung until cancelled; CI
Postgres "unhealthy" or "Wait for DB + ecto setup" fails on a `gamingpc-*`
runner; e2e-browser `Failed to sign in ... Too Many Requests`; marketing lychee
`https://sentry.io/privacy/ Connection refused`, Sentry release or source-map
upload fails on `gamingpc-*`/`minipc-*`; a job ends `failure` with a
step still `in_progress` and no log; engram-infra `main` red from
`bin/assert-main-tip.sh`; plugin release-please PR red on intermediate pushes;
a step reads a file another job overwrote (`JSONDecodeError` at char 0, empty
or truncated output).

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

## 4. sentry.io is DNS-sinkholed on gamingpc and minipc runners

**Symptom.** Every Sentry call fails on `gamingpc-*` and `minipc-*`, never on
`runner-*` (slowraid) or `fastraid-*`:
- marketing lychee: `https://sentry.io/privacy/ Connection refused`
- frontend build: `[sentry-vite-plugin] non-fatal: sourcemap/release step
  failed ... Failed to create release: Network error / fetch failed`
- backend `Sentry releases` step: exit 127, because `curl -sL .../get-cli/ | bash`
  downloaded nothing and the pipe hid it.

CI stays green (all three are non-fatal), so prod frontends built on those
runners ship without source maps. Tally 2026-11-03..05 on main: backend step
gamingpc+minipc 12/12 failed, slowraid 23/23 ok; frontend upload gamingpc+minipc
9/10 failed, fastraid 22/22 and slowraid 13/13 ok.

**Cause.** DNS, not IPv6. The LAN AdGuard Home pair (10.0.20.253 and
10.0.20.254) blocks sentry.io and answers `0.0.0.0` / `::`. The gamingpc and
minipc runner VMs resolve through their host's libvirt dnsmasq (10.20.98.1,
10.20.97.1), which forwards to that AdGuard pair. slowraid-runner uses 1.1.1.1
directly and is unaffected.

```
$ getent ahosts sentry.io          # on gpc-runner-vm / minipc-runner-vm
0.0.0.0  STREAM sentry.io
::       STREAM
$ dig +short @10.0.20.253 sentry.io
0.0.0.0
$ dig +short @1.1.1.1 sentry.io
34.8.226.60
```

The old entry here blamed IPv6 and said sentry-cli uploads succeeded on these
runners. Both were wrong. The lychee exclude (engram-marketing PR #252) only
hid the symptom.

**Visibility.** `.github/scripts/sentry-dns-check.sh` runs before both upload
paths in verify.yml and emits a `::warning::` naming the runner when sentry.io
resolves to a sinkhole address. The `Sentry releases` step also runs with
`pipefail` and `curl -f`, so a failed download fails at the download.

**Real fix (not in this repo).** Either allowlist `@@||sentry.io^$important` in
both AdGuard instances, or give `engram-runner-net` on gaming-pc and mini-pc
`<dns><forwarder addr='1.1.1.1'/></dns>` to match slowraid. Those libvirt
networks are not in the homelab ansible inventory yet.

**How found.** Correlating failures with runner name, then `getent` / `dig`
on a failing and a passing runner VM.

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

## 8. Runners on one host share /tmp

**Symptom.** Run 42375623594 (PR #2526, lint job, `mix deps.audit` step):
`JSONDecodeError: Expecting value: line 1 column 1 (char 0)` reading
`/tmp/audit.json`, though mix exited 0.

**Cause.** `runner-1` and `runner-2` are two runner services on the same
`github-runner` host and share its `/tmp`. runner-2 wrote a valid 35-byte
`{"pass":true,"vulnerabilities":[]}`; runner-1's concurrent lint job ran
`> /tmp/audit.json`, truncating it before runner-2's python read it. Any fixed
`/tmp/<name>` written in one command and read in a later one has this race.

**Fix.** Use `$RUNNER_TEMP/<name>` (per runner, per job, wiped after the job).
Converted in verify.yml: deps.audit json/err, the prebuild-mix deps/compile
logs, the OpenAPI drift files, and migration-gates' new-migrations and drops
lists. All run in the host shell; the compile logs are host-side redirects of
`docker run` output, so no mount is needed. A file shared by several steps is
set once via `$GITHUB_ENV` (`runner.temp` is not available in a job-level
`env:`, which is why `PREV_DIR` uses `run_id` instead).

**Left as is.** `/tmp/.X*-lock` (Xvfb owns those paths), the
`*_PREFIX`/`PREV_DIR` paths (already run-scoped), and
`/tmp/obsidian-stderr-<name>-<pid>.log` and
`/tmp/xvfb-stderr-<display>-<pid>.log` (pid-unique, written by
`e2e/helpers/obsidian.py`), and the `find /tmp -name '.ff*.node' -mmin +60
-delete` sweeps (host-wide cleanup of stale files, not a write-then-read).

**How found.** Comparing the lint job logs of both runners in the same window:
runner-2 logged `stdout bytes: 35`, then the decode error, while runner-1's
deps.audit was writing the same path.
