# Context Doc: Several unrelated e2e-crdt tests fail at once — check whether both Obsidian instances died

_Last verified: 2026-09-23_

## Status
Working (diagnosis method). The underlying contention is unfixed; the instrumentation that would make it self-evident is not built yet (see "The cheap fix").

## What This Is
A failure class, not a bug. When a handful of *unrelated* CRDT e2e tests go red in one
run — spanning live-binding, seq-gap-heal, orphaned-claim, web-to-obsidian — do not read
it as N independent bugs. First establish whether both headless Obsidian instances died
mid-run. If they did, every downstream failure is one event seen from several angles.

## Environment
- `e2e-crdt` job in `.github/workflows/verify.yml`, self-hosted isolated runner pool
- All 7 runners live on ONE 8 vCPU / 16 GB VM (10.20.99.10) — see `docs/context/runner-vm-setup.md`
- Two headless Obsidian (Electron) instances per run, driven over CDP, under Xvfb

## The signature

Worked example: run `35820290833`, 2026-09-23, backend sha `d986b641`, 6 failed / 22 passed.

1. **Last healthy CDP call**, then nothing:
   ```
   05:01:12 DEBUG urllib3.connectionpool: http://127.0.0.1:35673 "GET /json HTTP/1.1" 200 1111
   ```
2. **Backend logged both devices leaving 2s apart** — instance A (port 35673, display `:150`,
   device `0438c570…`) at `05:01:16.091`, instance B (port 50839, display `:149`, device
   `b9d349f4…`) at `05:01:18.882`, both:
   ```
   crdt leave / sync leave reason=":shutdown :local_closed"
   ```
   Both had launched fine at 04:59:15 / 04:59:19. Nothing asked them to shut down.
3. **Every later CDP call is refused**:
   ```
   ConnectionError: HTTPConnectionPool(host='127.0.0.1', port=50839) … [Errno 111] Connection refused
   ```
4. **The 120s content-propagation timeouts are the same event from the other side.** Three of
   the six "failures" are just assertions waiting on a push that a dead Obsidian can never send.
5. **The backend is exonerated by one observation.** `docker-compose.log` shows `POST 200 in 43ms`
   and normal fan-out right up to 05:07:18 — well past the death. Backend, DB, Qdrant and MinIO
   are all cleared without further digging.

## Why they died: shared-VM resource contention

At the moment of death, four heavy jobs were in flight on that one 16 GB box:

| Job | Run | Window | Runner |
|---|---|---|---|
| `e2e-crdt` | 5025 | 04:56:44–05:07:31 | runner-4 |
| `e2e-clerk` | 5025 | 04:57:31–05:04:48 | runner-5 |
| `e2e-clerk` | 5024 | 04:55:11–05:02:33 | — |
| `prebuild-ci-image` | 5026 | 04:57:15–05:08:22 | — |

Three concurrent Obsidian/Electron stacks plus a Docker image build, on 16 GB. The two
Electron processes are by far the largest RSS on the box, and both were killed two seconds
apart inside that peak. That is an OOM-killer cascade signature.

## Why this is inference, not proof — and the cheap fix

There is **no kill record**, because:

- `e2e/helpers/obsidian.py:292` launches Obsidian with `stderr=subprocess.DEVNULL`.
  Xvfb's stderr *is* captured (`/tmp/xvfb-stderr-<display>-<pid>.log`, same file, lines
  230–248); Obsidian's is thrown away.
- No `dmesg` and no memory snapshot is uploaded with the artifacts.

Capturing Obsidian's stderr to a file under `MARKER_PREFIX`, plus a `dmesg -T | tail -50`
and `free -m` step in e2e teardown, would make an OOM kill appear verbatim as
`Out of memory: Killed process … (obsidian)`. Roughly five lines of change, and it converts
this whole class from a multi-hour inference into a one-line grep. Issues **#1522** and
**#1503** have been open for weeks on exactly this ambiguity.

## Related live landmine (NOT the cause here)

`e2e-crdt` computes its Xvfb display window as `(GITHUB_RUN_NUMBER % 15) * 6 + 150`
(`verify.yml:1661`; `e2e-clerk` uses the same formula with base `+50`), and pre-cleanup runs
`pkill -9 -f "Xvfb :$d"` across that window. Only **15 buckets** — and because the runners
share a PID namespace, that pkill can reach another job's Xvfb. Two `e2e-crdt` runs whose
run numbers differ by a multiple of 15 collide outright.

No collision in this window (run 5025 → `:145-150`, 5026 → `:151-156`), but it will bite
eventually. Widening the modulo is cheap.

## How to tell this class from a real regression

Two tests, in order:

**(a) Did the same test pass in another run on the SAME sha?** In this wave,
`test_deaf_live_bound_note_converges_via_socket_replay` was the *only* failure of run
`35821588416` and it **passed** in run `35820290833` — same backend sha `d986b641`. An
intra-sha contradiction is something a regression cannot produce.

**(b) Check the plugin sha too, not just the backend.** Each run pins its own plugin SHA and
that axis is easy to miss. Here backend `2c747330` was green 14/14 consecutively
(2026-09-20 → 09-23, genuinely run, not fingerprint-skipped), and the only delta to the red
runs was **comment-only** changes on both sides (backend #1721, plugin #526).

## Gotchas

- **`e2e-crdt` failing gates nothing.** In run `35820290833` the `ci` aggregate concluded
  `success`, `alert-ci-failure` skipped, and `build-and-publish-image` + `mirror-image-to-ecr`
  both ran green. Per `docs/context/ci-pipeline-gating.md`, `ci` exits non-zero only if a
  *deterministic* need failed; `e2e-*` failures are warnings. So a red `e2e-crdt` neither
  blocks a release nor pages anyone — you have to go look.
- Three tests presenting as "content never propagated" and three presenting as "connection
  refused" is ONE fault, not two. Sort failures by timestamp before counting them as bugs.

## References
- `e2e/helpers/obsidian.py` (launch, stderr handling: lines 230–248 Xvfb, 291–292 Obsidian)
- `.github/workflows/verify.yml` — `e2e-crdt` job (display window at 1653–1666, pre-cleanup below it)
- `docs/context/runner-vm-setup.md` — the shared-VM runner pool
- `docs/context/ci-pipeline-gating.md` — what gates vs what only warns
- `docs/context/e2e-clerk-failure-taxonomy.md` — sibling taxonomy for the `e2e-clerk` job
- Issues #1522, #1503
