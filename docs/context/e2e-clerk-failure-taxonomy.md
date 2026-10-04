# Context Doc: e2e-clerk failure taxonomy (it is not one flake)

_Last verified: 2026-10-03_

## What This Is

A red `e2e-clerk` gets read as "the suite is flaky". It usually is not: it is
several unrelated problems wearing one red X, most of them not flakes. Read
this before touching an e2e-clerk failure, and before concluding a red
e2e-clerk on your PR is ambient noise.

> **e2e-* is report-only** (`verify.yml` `ci` job REPORT-ONLY block, #1076).
> A red e2e-clerk does NOT block merge; only the `release-v*` e2e gate in
> `deploy-prod.yml` does. So this suite is effectively unmonitored between
> releases. "Report-only" is not "doesn't matter".

## The taxonomy (2026-07-23 to 2026-08-04, 7 red nights)

| Test | Class |
|---|---|
| `test_34_folder_rename_propagation` | Real plugin bug, FIXED (Engram-obsidian#394) |
| `test_77_bulk_first_sync` | Load-sensitive throughput assert, FIXED (#1773: route count replaces wall clock) |
| `api_only/test_32_vault_api_key_isolation::test_mcp_search_spans_all_vaults_by_default` | Load-sensitive client timeout, FIXED (see below) |
| `test_30_sse_catch_up_multi`, `test_49`, `test_37`, `api_only/test_77_rename_repath_search` | Uninvestigated |

One red night had **no `FAILED` line at all**: a job-level failure, not a
test failure. Don't assume a red suite has a failing test.

### A whole category red together is infra or a dependency

Example: 5 attachment tests fail together with `POST /api/attachments → 502`
and `test_40_storage_endpoint` failing alongside. 502 means the storage
backend PUT/GET failed (see
`../engram-workspace/docs/context/attachment-502-storage-diagnosis.md`). CI
storage is the shared central FastRaid MinIO (`10.0.20.214:9101`, one
permanent `ci-e2e` bucket), so an outage or full disk hits every concurrent
job at once. `test_40` red is the tell that storage itself is down.

**Flakes are scattered; a whole category going red is a dependency or infra
regression.** Don't assume which. Before blaming your branch's diff, confirm
the same category passes on main in the same window. One green main run from
an hour earlier is not that check. Two real failures can overlap (2026-08: a
MinIO outage at e2e level and a genuine req 0.7 S3-GET break at unit level,
#1272); clearing one does not clear the other.

## Search ReadTimeout: budgets must nest

`test_32`'s `mcp_call("search_notes", ...)` failed with
`requests.exceptions.ReadTimeout`. Not an assertion failure; load-correlated.
Fixed via `SEARCH_TIMEOUT` in `e2e/helpers/latency.py`, used by
`ApiClient.search` and by `mcp_call` for embedding-bearing tools.
`e2e/unit/test_search_timeout.py` fails on any new `POST /search` that
bypasses the helper.

A client budget only means something if it can fire before the deadlines
wrapping it:

| bound | value |
|---|---|
| server query-embed ceiling | 45s (Ollama `:query`, flat: `retry: false`) |
| + the rest of the request | ~10s (sparse leg, decrypt, rerank, MMR) |
| `SEARCH_TIMEOUT` | **60s** |
| non-search MCP (`MCP_TIMEOUT`) | 30s |
| caller poll windows (`test_67`, `test_77`) | 90s |
| pytest-timeout per test (`e2e/pytest.ini`) | 180s |

`test_budget_nests_between_server_ceiling_and_caller_deadlines` asserts the
ordering and reads the 45s out of `ollama.ex` rather than hardcoding it, and
asserts `retry: false` is still there (the arithmetic is invalid without it).

Traps:

1. **The hundreds of Qdrant `points/scroll` calls before the timeout are not
   the fan-out.** They are the harness's own `wait_for_qdrant_indexed`
   polling. The cross-vault search issues zero scrolls. High scroll volume is
   a correlated symptom of a backed-up embed worker.
2. **Cross-vault search is not a fan-out.** It is one Qdrant query with the
   `vault_id` filter omitted (`Search.do_search/4`) plus one bulk
   `Vaults.list_for_ids`.
3. **The real cost is the one query embed.** CI's embedder is the shared
   FastRaid Ollama, which serializes requests, so a query embed queues behind
   128-chunk index batches (~4-5s each). Measured 2026-08-12: 0 batches
   ~0.12s, 3 batches ~13s.
4. **A timeout near the measured cost hides flakiness when a degradation path
   exists.** Hybrid falls back to keyword-only when the embed errors; a too-short
   embed budget would make `test_32` pass on the sparse leg while appearing to
   prove the vector path. The fallback is loud now (`Logger.warning` plus
   `[:engram, :search, :degraded]` in `Search.run_legs/5`).
5. **A timeout correct for an Oban worker is wrong for a request a user is
   blocked on.** Both embedders split the budget by `purpose:`; any new
   embedder must too.

## How to mine the nightly data

The ledger is the authoritative per-night record. Do not eyeball run lists.

```bash
# Per-suite pass rate over all recorded nights
git fetch origin ci-ledger
git show origin/ci-ledger:flake-ledger.jsonl | python3 -c "
import sys,json,collections
by=collections.defaultdict(lambda:[0,0])
for l in sys.stdin:
    if not l.strip(): continue
    d=json.loads(l); b=by[d['suite']]; b[0]+=1
    if d['result']!='success': b[1]+=1
for s,(n,f) in sorted(by.items()): print(f'{s:20} {n-f}/{n} pass')
"

# The run ids behind the red nights for one suite
git show origin/ci-ledger:flake-ledger.jsonl \
  | jq -r 'select(.suite=="e2e-clerk" and .result=="failure") | "\(.date) \(.workflow_run_id)"'

# Which tests failed in a given run
run=<run-id>
jid=$(gh api repos/engram-app/Engram/actions/runs/$run/jobs \
       --jq '.jobs[]|select(.name|test("e2e-clerk"))|select(.conclusion=="failure")|.id' | head -1)
gh api repos/engram-app/Engram/actions/jobs/$jid/logs \
  | grep -oE "FAILED tests/[a-zA-Z0-9_/]+\.py::[a-zA-Z0-9_]+" | sort -u
```

Ledger schema is one row per suite per night:
`{date, sha, workflow_run_id, suite, result, duration_s}`. No per-test field;
open the job log for test names.

`duration_s` is a tell on its own: successes clustered at 325-422s, failures
at 458-783s. A long red run is retry/timeout churn; a short red run is a
different failure mode.

## Reading the delivery oracle

`helpers/log_oracle.py` reports the causal-chain gap on timeout. Runs before
#1257 can show `materialized=no` for CRDT notes that were written, and evidence
mixed from both instances. If a message says `device=UNKNOWN (fell back to
the category heuristic)`, the evidence lines may belong to the other instance.

| Message | Meaning |
|---|---|
| `received=no materialized=no` | never reached the client |
| `received=yes materialized=no` | delivered, client never wrote |
| `received=yes materialized=yes last_write=0B` | client wrote the path, then left it empty |

## test_19's "SECURITY BREACH" message is a false alarm

`api_only/test_19_write_isolation` fails with:

```
AssertionError: SECURITY BREACH: isolation-user deleted sync-user's attachment!
assert 502 == 200
```

**It is not a breach.** The status code is the discriminator
(`attachments_controller.ex`): 404 means the row is gone or not visible; 502
means the row is **present** and the storage fetch failed. Cross-tenant
deletion is structurally impossible anyway (`Repo.with_tenant` plus a
per-user-DEK `path_hmac`). The DELETE returning 200 is the documented
idempotent contract. Chase the storage failure instead.

## test_66: a lying assertion message

`test_66_remote_logging_toggle::test_disable_stops_flush` fails with
`No pre-disable log entries reached the server within 5 s ... assert []`.

**Do not follow that message into `remote-log.ts`.** `test_16_remote_logging_pipeline`
exercises the same pipeline and passed in the same runs. It hits unrelated
PRs in different repos and passes on rerun with no code change, so a hit on
your PR is not evidence your PR did anything.

Two open issues carry competing hypotheses:

- **#1093**: the 5s `/logs` assert starves under the Bulk-note re-handshake
  storm (session-residue divergence).
- **#1421**: `flush_remote_logs` (`cdp.py`) waits a fixed 600 ms for the POST,
  a fixed sleep standing in for a load-variable round-trip; or `push_file_now`
  sometimes emits no rlog lines. Checking whether ANY `/logs` rows exist for
  the session user at failure time separates these.

Related: `list_logs(query=)` filters Python-side after the backend caps at
`limit`, so a log-noisy upstream test can push a marker out of the window
(#1419). Before blaming new tests for that, check **execution order**; tests
that ran after test_66 cannot have polluted it:

```bash
gh run view <run-id> --log | grep -oE "\[gw[0-9]\] \[ *[0-9]+%\] (PASSED|FAILED) tests/[^ ]*"
```

## Dependency traps (from the req 0.7 break, #1272)

- **`~> 0.6` does NOT mean `< 0.7.0`.** Two-component `~>` means `< 1.0.0`.
  Use three-component `~> 0.6.0` to hold a 0.x line. ex_aws declares
  `{:req, "~> 0.5.10 or ~> 0.6 or ~> 1.0"}`, which admits 0.7.x.
- **A 0.x minor is breaking by convention but "minor" to semver**, so
  Dependabot groups it with safe bumps. Dependabot automerge refuses to arm a
  `0.X → 0.Y` PR (engram-infra#909).

## Gotcha: the org runner list undercounts

`gh api /orgs/engram-app/actions/runners` returns a churning count: runners
are ephemeral JIT registrations that deregister per job. A single snapshot
showing a missing runner is not an outage; confirm on the VM.
