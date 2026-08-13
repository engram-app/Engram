# Context Doc: e2e-clerk failure taxonomy (it is not one flake)

_Last verified: 2026-08-12_

## Status
Working. Taxonomy produced from 12 nights of ledger data on 2026-08-05.
`test_34` is FIXED (Engram-obsidian#394). One diagnosis in the first draft of
this doc was WRONG and is kept, corrected, under "MISDIAGNOSIS ON RECORD" —
the point of that section is the check that would have caught it.

## What This Is

`e2e-clerk` passed **5 of 12 nights** when this was written. That number gets
read as "the suite is flaky", which is wrong in a way that costs hours: it is
**four unrelated problems** wearing one red X, and three of them are not
flakes at all.

Read this before touching an e2e-clerk failure, and before concluding that a
red e2e-clerk on your PR is ambient noise.

> **e2e-* is report-only** (`verify.yml:3742`, decision #1076). A red
> e2e-clerk does NOT block merge — the deterministic jobs are the gate. That
> demotion was correct given the pass rate, but it means this suite is
> effectively unmonitored: nobody can distinguish a real break from the
> baseline. Do not treat "it's report-only" as "it doesn't matter".

## The taxonomy (7 red nights, 2026-07-23 → 2026-08-04)

| Test | Nights | Class |
|---|---|---|
| `test_34_folder_rename_propagation::test_folder_rename_new_paths` | **5/7** | **Real bug — FIXED**, Engram-obsidian#394 |
| `test_77_bulk_first_sync::test_bulk_first_sync_timing` | **5/7** | Load-sensitive throughput assert |
| `test_30_sse_catch_up_multi::test_channel_catch_up_multi` | 3/7 | Uninvestigated |
| `test_49`, `test_37`, `api_only/test_77_rename_repath_search` | 1/7 each | Uninvestigated |
| `api_only/test_32_vault_api_key_isolation::test_mcp_search_spans_all_vaults_by_default` | (post-window) | **Load-sensitive client timeout — FIXED**, see below |

Two tests account for nearly all of it. Fix those two and the suite's pass
rate roughly inverts.

One red night (`30891054768`) had **no `FAILED` line at all** — a job-level
failure, not a test failure. Don't assume a red suite has a failing test.

### Not in the taxonomy: the attachment-502 cluster (CI storage is down)

A recurring, separate failure: **5 attachment tests fail together**
(`test_33` ×2, `test_79` ×2, `test_80`), with

```
test_40_storage_endpoint::test_storage_endpoint   FAILED
POST /api/attachments → 502
```

502 means the storage backend PUT/GET failed (see
`attachment-502-storage-diagnosis.md`). Since 2026-08-05 that backend is the
**central FastRaid MinIO** (`10.0.20.214:9101`), not a per-stack sidecar — so
a 502 can now mean the shared host is down or full rather than anything
run-specific, and it will hit every concurrent job at once. Every job shares
the one permanent `ci-e2e` bucket. `test_40` failing
alongside is the tell that storage itself is down, not that any one code path
regressed. Observed on **main** and on unrelated feature branches in the same
window, so it is not branch-specific.

> **MISDIAGNOSIS ON RECORD (2026-08-05).** This cluster first showed up on a
> `dependabot/hex/mix-minor` PR that also bumped `req 0.6.3 → 0.7.1`, and I
> attributed it to req breaking the ex_aws S3 adapter — the story fit
> (`config :ex_aws, :http_client, ExAws.Request.Req`, and req 0.7.0 really
> does carry breaking changes to that step API). It was wrong. The same
> cluster then failed on **main at req 0.6.3**. The "asymmetric damage"
> reading (PutObject fine, GetObject broken) came from ONE test's trace in
> ONE run; `POST` 502s too.
>
> The lesson is the check I skipped: **before blaming a branch's diff for a
> category failure, confirm the same category passes on main in the same
> window.** One green main run from an hour earlier is not that check.
>
> **PARTLY RE-RETRACTED (#1272).** The e2e-502 half above is right: those were
> CI storage. The "req is innocent" half is not — req 0.7 really does break
> S3 GETs, just not via the step API and not visibly through the 502s. See
> [req 0.7 rewrites bodyless GETs into POSTs](#req-0x-ceiling). Two unrelated
> real failures were live at once.

**Heuristic that still holds: a whole *category* going red together (all
attachments, all search) is a dependency or infra regression, not a flake —
flakes are scattered.** Just don't assume *which*.

### Not in the taxonomy: the search ReadTimeout (client budget, not fan-out)

`api_only/test_32_vault_api_key_isolation::test_mcp_search_spans_all_vaults_by_default`
fails intermittently with `requests.exceptions.ReadTimeout ... (read timeout=10)`
on `api.mcp_call("search_notes", {"query": "Secret"})`. It is **not** an
assertion failure — no correctness claim is ever evaluated. Observed on main
and on unrelated feature branches in the same window, passing on those same
branches at other times: load-correlated, not branch-correlated.

**Class: load-sensitive client timeout. FIXED** — `SEARCH_TIMEOUT` in
`e2e/helpers/latency.py`, used by `ApiClient.search` and by `mcp_call` for the
embedding-bearing tools.

> **`ApiClient.search` had ZERO callers.** Every real `/search` in the suite was
> a hand-rolled `client.session.post(...)` with its own `timeout=30`
> (`test_50`, `test_67`, `test_77`), which is exactly why the helper's budget
> could drift unnoticed. Fixing the helper alone would have fixed nothing. All
> three now route through it, and `e2e/unit/test_search_timeout.py` fails on any
> new `POST /search` that doesn't.
>
> **The guard for that was itself broken on the first cut**, and it is worth
> knowing why: it tested `"/search" in line and ".post(" in line` per line,
> while every real offender splits the call across lines. It reported green
> against three live offenders. A guard that cannot fail is worse than no guard
> — it launders the claim. It now scans file text, and a companion test pins
> both the single- and multi-line shapes so the matcher itself can't silently
> stop working.

**Budgets must nest.** The client budget only means something if it can fire
before the deadlines wrapping it:

| bound | value |
|---|---|
| server query-embed ceiling | 45s (Ollama `:query`, **flat** — `retry: false`) |
| + the rest of the request | ~10s (sparse leg, decrypt, rerank, MMR) |
| `SEARCH_TIMEOUT` | **60s** |
| non-search MCP (`MCP_TIMEOUT`) | 30s |
| caller poll windows (`test_67`, `test_77`) | 90s |
| pytest-timeout per test (`e2e/pytest.ini`) | 180s |

Three ways this got mis-derived before it was right, all caught in review:

- **120s** exceeded every window *below* it, so it was unreachable in the very
  tests that use it — a slow search would eat a 90s poll loop and be reported as
  "the repath never landed", or be killed by SIGALRM.
- **60s compared against the embed alone.** The request continues past the embed
  (sparse leg, decrypt, rerank, MMR), so "clears the server ceiling" has to mean
  the *whole request*, not one leg of it.
- **The embed ceiling wasn't flat.** `retry_fast_transient?/2` declines to retry
  a `:timeout` — but retries every *other* transport error, so a late
  `:econnreset` cost ~4 × 45s ≈ 187s. `:query` now uses `retry: false` (as Voyage
  always did), which is what makes 45s a real ceiling.

`test_budget_nests_between_server_ceiling_and_caller_deadlines` asserts the whole
ordering, and reads the 45s **out of `ollama.ex`** rather than hardcoding it — a
literal would have gone green if the Elixir side later drifted past the client
budget, which is the same guard-that-cannot-fail trap as the broken matcher
above. It also asserts `retry: false` is still there, since the arithmetic is
invalid without it.

Non-search MCP tools get their own 30s bound rather than `DELIVERY_TIMEOUT`:
that constant is a *polling-loop* budget, and at 120s two wedged calls (test_46
makes five) blow the 180s pytest-timeout, turning a clean `ReadTimeout` into a
SIGALRM traceback.

Two traps this one sets, both worth knowing because the obvious reading is
wrong in both cases:

1. **The "hundreds of Qdrant `points/scroll` calls" right before the timeout
   are not the fan-out.** They are the harness's own
   `wait_for_qdrant_indexed`, polling once a second (up to 90s, four calls in
   that file), logged by urllib3 from the *pytest* process. The cross-vault
   search issues **zero** scrolls. High scroll volume is a *correlated
   symptom* of the same load — many polls means the embed worker was backed
   up — not the cause.

2. **Cross-vault fan-out is not a fan-out.** `#985`'s cross-vault default is
   one Qdrant query with the `vault_id` filter simply omitted
   (`Search.do_search/4`), plus one bulk `Vaults.list_for_ids`. There is no
   per-vault loop and no N+1. Prod bears out the shape:
   `engram_prom_ex_search_request_duration_milliseconds` gives cross-vault a
   **303ms** mean vs **194ms** single-vault.

The actual cost is the **one query embed**. CI's embedder is the shared
FastRaid Ollama (`10.0.20.214:11434`), which serializes requests, so a
synchronous query embed queues behind the embed worker's 128-chunk index
batches (`@embed_batch_size`). Measured 2026-08-12 with `mxbai-embed-large`:

| In-flight index batches | Query embed latency |
|---|---|
| 0 (idle) | ~0.12s |
| 1 | ~4.3s |
| 2 | ~8.4s |
| 3 | **~13.1s** — exceeds the old 10s |

One 128-chunk batch alone occupies Ollama for ~5.2s. The test's own fixture
seeds notes immediately before searching, so it partly *creates* the
contention it then trips over; concurrent e2e jobs supply the rest.

### The self-host gap this uncovered (FIXED in the same PR)

Measuring the above turned up a real product bug next to the harness one.
`Search.embed_for_search/2` passes `purpose: :query` specifically so "a bulk
indexing burst can't starve synchronous user search" — but that only routed a
separate **Voyage** rate-limit bucket. `Engram.Embedders.Ollama` dropped
`purpose:` on the floor, so **self-host had no equivalent guard**: its
synchronous search inherited the 120s *indexing* `receive_timeout`, and a real
MCP client would hang for two minutes rather than degrade.

`Engram.Embedders.Ollama.request_defaults/1` now mirrors Voyage's shape and
gives `:query` a 45s budget. Divergences from Voyage, documented at the function:

- **45s, not Voyage's 5s.** Voyage's 5s guards a remote brownout, where slow
  means trouble. This guards *local queueing*, where slow is the normal cost of
  concurrent indexing and the vector result is still worth waiting for.
- **Retries kept, not `retry: false`.** `retry_fast_transient?/2` refuses to
  retry a `receive_timeout`, so the timeout itself can't compound — though a
  fast 5xx then a hang still costs the budget plus Req backoff.

> **The trap inside the fix (caught in review, worth keeping).** The first cut
> used **15s**, only ~1.9s above the measured 3-batch depth. Under exactly the
> load this change exists to survive, the embed would have timed out, hybrid
> would have silently dropped to keyword-only, and `test_32` would have gone
> green on the sparse leg — `"Secret"` is a literal token in both seeded notes —
> while appearing to prove the cross-vault *vector* path. That closes a flake by
> deleting the thing under test. When a degradation path exists, a timeout near
> the measured cost doesn't fix flakiness, it hides it.
>
> Because that degradation is now a routine outcome rather than a 120s hang, the
> keyword fallback in `Search.run_legs/5` was made **loud** — a `Logger.warning`
> plus an `[:engram, :search, :degraded]` counter. Silent degradation returns a
> normal 200 with plausible results, so without a signal an operator with a slow
> Ollama just gets quietly worse search forever.

This degrades rather than fails: hybrid falls back to keyword-only when the
embed leg errors, and hybrid is the default for both MCP `search_notes` and
`POST /search`.

> **The general trap:** a timeout that is correct for an Oban worker is wrong
> for a request a user is blocked on. Both embedders now split the budget by
> `purpose:`; any third embedder must too, or it silently reintroduces this.

## How to mine the nightly data

The ledger is the authoritative per-night record — do not eyeball run lists.

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
run=30341324024
jid=$(gh api repos/engram-app/Engram/actions/runs/$run/jobs \
       --jq '.jobs[]|select(.name|test("e2e-clerk"))|select(.conclusion=="failure")|.id' | head -1)
gh api repos/engram-app/Engram/actions/jobs/$jid/logs \
  | grep -oE "FAILED tests/[a-zA-Z0-9_/]+\.py::[a-zA-Z0-9_]+" | sort -u
```

The ledger schema is one row per suite per night:
`{date, sha, workflow_run_id, suite, result, duration_s}`. There is **no
per-test field** — you must open the job log for test names.

`duration_s` is a useful tell on its own: e2e-clerk successes clustered at
325–422s while failures ran 458–783s. A long red run is retry/timeout churn;
a *short* red run (the 323s one) is a different failure mode entirely.

## Reading the delivery oracle (post-#1257)

`helpers/log_oracle.py` reports the causal-chain gap on timeout. Two traps,
both fixed in #1257 but worth knowing because **old failure messages in old
runs are still misleading**:

1. **`materialized=no` used to be a lie on CRDT notes.** The oracle only
   matched the REST pull path (`"Created:"`/`"Applied:"`). A CRDT-bound
   materialize emits neither, so it reported `materialized=no` even when the
   file had been written. It now also reads the `vault` category from
   `diagnostics.ts`, which observes Obsidian's own vault events — i.e. the
   filesystem, not a code path.

2. **Evidence used to mix the two instances.** `vault_a` and `vault_b` share
   one `client_id`, so the SENDER's healthy `bytes=22` appeared in the
   RECEIVER's evidence. The oracle now filters on `device_id` (read from
   `<vault>/.obsidian/plugins/engram-vault-sync/data.json`) and says which
   mode it used — `[device=abc12345]` vs `[device=UNKNOWN (fell back to the
   category heuristic)]`. **If you see `device=UNKNOWN`, the evidence lines
   may belong to the other instance.**

The message now carries `last_write=<N>B`. That distinguishes:

| Message | Meaning |
|---|---|
| `received=no materialized=no` | never reached the client |
| `received=yes materialized=no` | delivered, client never wrote |
| `received=yes materialized=yes last_write=0B` | **client wrote the path, then left it empty** |

That third case is a completely different bug from the second and a boolean
flag reports them identically.

## test_34: what is actually happening

The test renames a folder via the API and asserts B sees the notes at the new
paths. B ends up with a **0-byte file** at the new path, so
`wait_for_delivery`'s non-empty guard never satisfies and it times out at 120s.

Receiver-side log sequence from run `30341324024`:

```
ws:      Event: upsert note: E2E/RenamedFolder34/Note1.md
ws:      CRDT-managed: skipping legacy body apply for E2E/RenamedFolder34/Note1.md
ws:      Delete is rename old-leg (id relocated to NEW); old path trashed, room preserved
pull:    CRDT discovery: enrolling new note E2E/RenamedFolder34/Note1.md
vault:   create path=E2E/RenamedFolder34/Note1.md bytes=22
vault:   create path=E2E/RenamedFolder34/Note1.md bytes=0     <- ends empty
pull:    Id-keyed move: OLD -> NEW (id=019fa7cb-...)
```

**ROOT CAUSE (confirmed by code, fixed in Engram-obsidian#394).** Two paths
race for the new path and each is defensible alone:

1. **CRDT discovery** (`sync.ts:5697`) calls `flushFromCrdt(newPath, content)`
   for a note this device has never had on disk. `flushFromCrdt`'s
   content-loss guard is gated on `file instanceof TFile`, so its **CREATE**
   branch writes an empty body with no guard at all → 0-byte file.

2. **`moveIfIdRelocated`** reads the OLD file's real body, then hits its
   CREATE-ONLY GUARD — `if (getAbstractFileByPath(newPath))` → skip.

The guard's own comment states its premise: an existing `newPath` means *"a
CONCURRENT doc-triggered flush already wrote"* a body newer than ours. **That
premise is false when the concurrent flush wrote an EMPTY one**, and the skip
then discards the only copy of the content — which that path had just read off
disk specifically to preserve.

**"Exists" is not "has content".** The fix narrows the guard to yield only to
a target that actually holds content. It was made there, not at discovery,
because that is where content is *destroyed*: an empty placeholder is
defensible (it makes the note visible pending STEP2 backfill), silently
dropping a body you are holding is not.

Note the diagnostic trap this sat behind: the nightly message read
`received=yes materialized=no`, which was wrong on BOTH counts — see
"Reading the delivery oracle" above.

Related prior art: `folder-rename-mint-resurrection.md`,
`crdt-wrong-mint-cross-file-overwrite.md`.

## test_19's "SECURITY BREACH" message is a false alarm

`api_only/test_19_write_isolation` fails with:

```
AssertionError: SECURITY BREACH: isolation-user deleted sync-user's attachment!
assert 502 == 200
```

**It is not a breach.** The status code is the discriminator
(`attachments_controller.ex`):

- **404** (:385) — row gone or not visible to this user
- **502** (:418) — row **present**, storage fetch failed

It got 502, so the row survived. Cross-tenant deletion is structurally
impossible anyway: `Repo.with_tenant(user.id, …)` plus a `path_hmac` derived
from each user's own DEK, so the other user computes a different HMAC and
cannot match the row. The DELETE returning 200 is the documented idempotent
contract (`"Idempotent — always returns deleted: true"`), not evidence of a
delete.

The real cause is a storage-layer failure. Chase it via
`attachment-502-storage-diagnosis.md`.

## req 0.7 rewrites bodyless GETs into POSTs {#req-0x-ceiling}

**RESOLVED 2026-08-05 (#1272). Now on req 0.7.2; there is no 0.6 ceiling any
more.** Both earlier accounts of this were wrong, in opposite directions:

- The original `mix.exs` comment blamed req 0.7's removal of the `run_finch` /
  `put_plug` step API. `ExAws.Request.Req` never used those. It is twenty
  lines of high-level `Req.request/1`.
- The misdiagnosis note above then over-corrected to "req 0.7 was never shown
  to break anything here." That is also false. It was never shown *by the e2e
  502s*, which really were CI storage. It reproduces cleanly one layer down.

The actual break, reproducible in `Engram.Storage.S3Test` against Bypass on
localhost with no CI involved:

```
Req.request(method: :get, body: "",  ...)  -> wire method POST
Req.request(method: :get, body: nil, ...)  -> wire method GET
Req.request(method: :get, <no :body>, ...) -> wire method GET
Req.request(method: :delete, body: "", ...) -> wire method DELETE
```

req 0.7 upgrades an explicit `method: :get` to `POST` whenever a non-nil
`:body` is present. `:method` defaults to `:get`, so req cannot distinguish
"the caller asked for GET" from "the caller said nothing", and reads a body as
"you meant POST". Other verbs are left alone. `ExAws.Request.Req` always passes
`""` rather than `nil`, so **every S3 GetObject left as a POST**: uploads kept
returning 200 and every download failed. `Engram.Aws.ReqClient` normalises `""`
to `nil` for `:get`/`:head` and delegates; `test/engram/aws/req_client_test.exs`
asserts the verb on the wire.

**Two real failures overlapped in the same window** — a genuine req break at
unit level and a genuine MinIO outage at e2e level. Clearing one did not clear
the other, and each in turn looked like the whole story. "Not proven by this
evidence" is not "disproven"; when a retraction lands, re-derive at the
cheapest layer that can still show the effect rather than concluding from the
expensive one.

Two traps worth carrying elsewhere:

- **`~> 0.6` does NOT mean `< 0.7.0`.** Two-component `~>` means
  `< 1.0.0`. You need the three-component `~> 0.6.0` to hold a 0.x line.
  ex_aws 2.7.0 fell into exactly this — it declares
  `{:req, "~> 0.5.10 or ~> 0.6 or ~> 1.0"}`, which *admits* 0.7.x, so Hex
  resolves it happily and nothing upstream protects you.
- **A 0.x minor is breaking by convention but a "minor" to semver**, so
  Dependabot groups it with safe bumps. `dependabot-automerge.yml` now
  refuses to arm any PR carrying a `0.X → 0.Y` transition (engram-infra#909).
  engram has 13 deps on `~> 0.x`.

## What is still open

- `test_34` — **FIXED** (Engram-obsidian#394), verified green in the
  plugin-dispatched e2e run 31024858500 (91 passed; test_34 absent from the
  failures). Root cause was NOT a delivery gap: `moveIfIdRelocated`'s
  CREATE-ONLY GUARD treated "newPath exists" as "newPath has content" and
  discarded the body it had just read off disk, because CRDT discovery had
  already created a 0-byte placeholder there (`flushFromCrdt`'s content-loss
  guard is gated on `file instanceof TFile`, so its CREATE branch has no
  empty check).
- **CI storage (MinIO) failing on main** — the attachment-502 cluster above.
  Live and unowned as of 2026-08-05.
- `test_77` — the assert is `1000 notes in 120s`; observed 826 in 122.4s on a
  saturated runner pool. The documented pattern for this class is *move
  load-variable cost OUT of the timed window, never loosen the assert*.
- `test_30`, `test_49`, `test_37`, `api_only/test_77` — uninvestigated.

## Gotcha: the org runner list undercounts

`gh api /orgs/engram-app/actions/runners` returns a **churning** count —
runners are ephemeral JIT registrations that deregister per job. Three
samples 4s apart returned 9, 8, then 10. A single snapshot showing a missing
runner is not an outage; confirm on the VM before chasing it.
