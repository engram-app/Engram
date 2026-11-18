# Context Doc: two e2e jobs on one host killed each other's Xvfb displays

_Last verified: 2026-11-18_

## Trigger

All of one e2e job's Obsidian instances die at the same second (`Xvfb DIED
BEFORE TEARDOWN ... rc=-9`, `X connection error received` in Obsidian stderr),
then every later test fails `[Errno 111] Connection refused` until the infra
breaker aborts. Or you are touching how `verify.yml` picks Xvfb displays, or
any cleanup that kills Xvfb.

## What happened (run 44354068376, 2026-11-18)

- e2e-clerk picked its 10-display window as `GITHUB_RUN_NUMBER % 15`. Runs
  9148 and 9163 are 15 apart, so both owned `:180..:189`, on two runner
  services (`runner-2`, `runner-3`) of the same `github-runner` host.
- Run 9148's job started at 18:02:26. Its pre-cleanup ran
  `pkill -9 -f "Xvfb :$d"` over `:180..:189` at 18:02:33.3. Run 9163's A, B
  and C Xvfbs died at 18:02:33.98, mid test_77. Nine tests failed after it,
  none of them a product bug; minutes later the same pkill pattern killed
  run 9148's own A and B.
- The SIGKILL looks like the OOM killer in `obsidian.py`'s death report. Three
  Xvfbs dying in one second, Obsidian left alive until its X connection broke,
  is a pkill, not OOM (the OOM killer takes the biggest RSS, which is Electron).

## The fix

- `ci/bin/claim-display-window <family> <stride> <offset> <slots>`: the first
  free slot under `/tmp/engram-ci-display-locks/` (host-wide, the runners share
  `/tmp`), held by an `flock` on a background `sleep` for the job's lifetime.
  Teardown kills the holder; if teardown never runs, the runner's end-of-job
  process cleanup does, and the kernel frees the lock. Windows: clerk
  `BASE = slot*10 + 3509` (`:3500..:3649`), crdt `BASE = slot*6 + 4005`
  (`:4000..:4089`). The claim step has `timeout-minutes: 1` and the script
  gives up after 5 s if the lock file cannot be opened.
- The new ranges are chosen so no OLD-workflow kill can reach them.
  `pkill -f "Xvfb :50"` is a regex search, so it also matches `:500`; the
  old ranges were `:50..:199` and `:245..:334`. Every prefix of the new
  numbers (35, 36, 350..364, 40, 400..408) is outside those, so an
  unrebased branch's range kill cannot hit a new-style job (and the new
  jobs kill nothing by range at all).
- The harness writes `<config_dir>.xvfb.pid` (`<pid> <display>`) for each Xvfb
  (`e2e/helpers/obsidian.py`). `ci/bin/release-display-window` kills only those
  pids, and only while `/proc/<pid>/cmdline` still reads `Xvfb ... :<display>`.
  Pre-cleanup kills no Xvfb at all; the harness's per-display pre-flight kill
  stays, because the window is now owned.
- `e2e/unit/test_display_window.py` is a regression lock (it fails without
  the fix only because the scripts are absent): distinct windows for
  concurrent claims, free again when the holder dies, a bounded failure on an
  unopenable lock, a neighbour's Xvfb and a reused pid surviving release, the
  old arithmetic giving runs 9148 and 9163 one window, and no old range kill
  matching a new display.

## Gotchas

- Each branch runs ITS OWN copy of verify.yml (push-triggered). Unrebased
  branches keep the run-number window and the range pkill, so two OLD jobs
  can still collide with each other until they rebase; old and new jobs
  cannot, by the range choice above. Never move a new range back under a
  number an old pattern prefixes (`e2e/unit/test_display_window.py` checks).
- Claim the window AFTER `actions/checkout` (the script lives in the repo).
  Nothing before checkout may need the window.
- Never test liveness of a background claim with `kill -0`: a failed claim is
  an unreaped zombie and still answers. The script reports through a file.
- `e2e-browser` and `headless-protocol` start no Xvfb; only e2e-clerk and
  e2e-crdt claim windows.

## References

- `.github/workflows/verify.yml`, e2e-clerk and e2e-crdt "Claim a display
  window" and "Tear down" steps
- `docs/context/e2e-simultaneous-failures-obsidian-death.md` (the OOM sibling;
  its "live landmine" note was this bug)
- `docs/context/ci-runner-network-and-disk-gotchas.md` §8 (runners on one host
  share `/tmp`)
