# Context Doc: e2e-clerk failure taxonomy (it is not one flake)

_Last verified: 2026-08-05_

## Status
Working (method valid). Produced the taxonomy below from 12 nights of ledger
data on 2026-08-05. `test_34` remains unfixed — see "What is still open".

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
| `test_34_folder_rename_propagation::test_folder_rename_new_paths` | **5/7** | **Real bug** — receiver ends with a 0-byte file |
| `test_77_bulk_first_sync::test_bulk_first_sync_timing` | **5/7** | Load-sensitive throughput assert |
| `test_30_sse_catch_up_multi::test_channel_catch_up_multi` | 3/7 | Uninvestigated |
| `test_49`, `test_37`, `api_only/test_77_rename_repath_search` | 1/7 each | Uninvestigated |

Two tests account for nearly all of it. Fix those two and the suite's pass
rate roughly inverts.

One red night (`30891054768`) had **no `FAILED` line at all** — a job-level
failure, not a test failure. Don't assume a red suite has a failing test.

### Not in the taxonomy: dependency regressions

A `dependabot/hex/mix-minor` run failed **6 attachment tests at once**
(`test_33`, `test_79`, `test_80`, `api_only/test_19`) while main was green
that same hour. That was not flake and not test_34's class — it was
`req 0.6.3 → 0.7.1` breaking the ex_aws S3 adapter. See
[[req-0x-ceiling]] below.

**Heuristic: a whole *category* of tests going red together (all attachments,
all search) on one branch is a dependency or infra regression, not a flake.**
Flakes are scattered.

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

**HYPOTHESIS — NOT YET CONFIRMED.** Two code paths both claim the new path:
CRDT discovery enrollment (`sync.ts:5697`) and the id-keyed move
(`sync.ts:5113`). Discovery calls `flushFromCrdt(normalized, content)`; if
that `content` is empty, the empty-write guard at `sync.ts:1300`
(*"refused empty over Nb ... CRDT doc still holds content"*) **cannot fire,
because it compares against existing content and the file does not exist
yet**. Nothing protects the first write.

This was not confirmed because pre-#1257 evidence could not be attributed to
a device — the `bytes=22` and `bytes=0` lines above may be from different
instances. **Do not act on the hypothesis without attributed evidence.**

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

## req 0.x ceiling {#req-0x-ceiling}

`config :ex_aws, :http_client, ExAws.Request.Req` routes every S3/KMS call
through `req`. req 0.7.0 shipped three `(BREAKING CHANGE)` entries against
that step API, and the damage is asymmetric and easy to misread: **PutObject
kept returning 200 while GetObject 502'd**, so uploads look healthy and every
download fails.

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

- `test_34` — unfixed. Needs one nightly with #1257 merged, then read the
  attributed `last_write=` verdict before touching `sync.ts`.
- `test_77` — the assert is `1000 notes in 120s`; observed 826 in 122.4s on a
  saturated runner pool. The documented pattern for this class is *move
  load-variable cost OUT of the timed window, never loosen the assert*.
- `test_30`, `test_49`, `test_37`, `api_only/test_77` — uninvestigated.

## Gotcha: the org runner list undercounts

`gh api /orgs/engram-app/actions/runners` returns a **churning** count —
runners are ephemeral JIT registrations that deregister per job. Three
samples 4s apart returned 9, 8, then 10. A single snapshot showing a missing
runner is not an outage; confirm on the VM before chasing it.
