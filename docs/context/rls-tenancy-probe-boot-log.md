# Context Doc: Reading the RLS tenancy probe's boot log

_Last verified: 2026-09-25_

## Status

**The cutover is DONE.** Prod and staging both enforce RLS at the database
layer as of 2026-09-25. This doc is now history plus a runbook for re-reading
the probe; it is no longer describing a live defect.

Sequence, all in one night:

1. `0.30.0` shipped a behavioural probe that **never executed** — `mode:
   :savepoint` failed on every outermost caller (#1745).
2. `0.31.0` fixed that. The probe ran on prod for the first time and returned
   **`:bypassed`**: the app's connection could read other tenants' rows.
3. `0.31.1` fixed `OrphanSweep`'s reads (#1746/#1747) so the cutover could not
   trigger mass Qdrant deletion.
4. engram-infra#1243 flipped `DATABASE_URL` to `engram_app` and added the
   maintenance pool. engram-infra#1248 did the same for staging.

Both environments now log `RLS enforced; maintenance pool configured`.

## The measurement that justified the flip

**On prod, 2026-09-25 ~01:06 UTC, task definitions `engram-saas-prod:171` and
`engram-worker-prod:22`, the probe returned `:bypassed`.** Unanimous across all
three tasks.

```
RLS role attributes and observed behaviour DISAGREE.

pg_roles says: enforced
what this connection can actually see says: bypassed
```

The probe set `app.current_tenant` to the all-zeros UUID — a tenant that owns
nothing — and still saw rows. That CONFIRMED #1649.

Corroborating check, and the one to repeat before trusting any future verdict:
the `DBConnection.TransactionError: transaction is not started` line that
preceded every boot report through 0.30.0 was **absent** from the 0.31.0 boot
window. While it is present the probe is not running and its answer is noise.

## Verification after the flip

Not read off a log line. Tested adversarially against prod as the real
`engram_app` credential, through the SSM bastion:

```
no tenant set:          all 11 tenant tables -> 0 rows
as tenant A:            only A's rows, 0 foreign
as A, read B:           0
as A, UPDATE/DELETE B:  0 rows affected
as A, INSERT owned by B: ERROR new row violates row-level security policy
as A, INSERT owned by A: INSERT 0 1      <- control; the rejections are not vacuous
SET ROLE engram_admin:  permission denied
DISABLE ROW LEVEL SECURITY / CREATE POLICY: must be owner
pg_shadow:              permission denied
engram_app memberships: (none)
```

The control matters. Without it, a connection that rejected *everything* would
have produced the same nine passing lines.

`pg_stat_activity` confirmed the flip is real rather than configured: 71
connections as `engram_app`, 3 as `engram_admin` (the maintenance pool, one per
task).

### The one deliberate exception

`api_keys` returns rows when **no tenant is set** — every other tenant table
returns zero. That is the `api_keys_discovery` policy
(`20260918120000_add_api_keys_discovery_policy.exs`):

```sql
FOR SELECT USING (COALESCE(current_setting('app.current_tenant', true), '') = '')
```

`SELECT`-only, matches only while the tenant is unset, and the column is
`key_hash` rather than a usable key. Without it `validate_api_key/1` cannot work
at all — that read is a tenant *discovery*, so there is nothing to scope by, and
every API-key request 401s. Confirmed empirically that it grants no writes:
`DELETE FROM api_keys` with no tenant affects 0 rows.

Keep `20260918120000` out of any rollback runbook. Its `down/0` restores the
outage.

## Why #1726's mechanism is now settled enough

Same attributes, opposite behaviour, one variable:

| | staging (pre-flip) | prod (pre-flip) |
|---|---|---|
| role | `engram_app` | `engram_admin` |
| `rolsuper` / `rolbypassrls` | false / false | false / false |
| role memberships | **none** | `pg_read_all_data`, `pg_write_all_data`, `rds_superuser`, … |
| `observed_enforcement/0` | `:unknown` | `:bypassed` |
| `count(*) from notes`, no tenant | 0 | 3,602 (#1649) |

Both databases had `ENABLE` + `FORCE ROW LEVEL SECURITY` on all eleven tenant
tables, verified. So the interrupted-`NO FORCE`-migration theory this doc used
to push is **dead** — staging had identical flags and behaved correctly.

The remaining difference is role membership. Post-flip `engram_app` on prod has
none, and prod now behaves exactly like staging did. That is enough to act on;
it is not a line-by-line explanation of which membership does it, and nobody has
needed one since.

## What was wrong

The probe ran `Repo.transaction(&probe/0, mode: :savepoint)`. `mode: :savepoint`
issues a `SAVEPOINT`, which is only valid inside an existing transaction. Every
production caller is outermost — `init/1` at boot, and the top of the
`OrphanSweep` and `CrdtBloatSweep` Oban jobs — so on prod the transaction failed
with `DBConnection.TransactionError: transaction is not started`, took the
pooled connection down with it, and `run_probe/0`'s catch-all mapped the result
to `:unknown`.

So `observed_enforcement/0` returned `:unknown` on prod every single time,
without reading any tenant table.

Two things hid it:

- **`:unknown` is a legitimate verdict.** A fresh install with no rows returns
  it. So `combine/2` quietly fell back to the attribute answer, and
  `report_divergence/2` stays silent whenever either signal is `:unknown`.
  Nothing logged a defect.
- **Every test ran under `Engram.DataCase`.** The Ecto sandbox already holds a
  transaction open, so the savepoint was always valid in the suite. The one
  shape that ships was the one shape never exercised.

The visible symptom was in prod logs the whole time, one line before every
`TenancyGuard` boot report, and was read as unrelated noise:

```
Postgrex.Protocol (#PID<0.3706.0> ({Postgrex.Protocol, "engram_saas_prod"}))
  disconnected: ** (DBConnection.TransactionError) transaction is not started
```

It also recurred every 6 hours on the sweep jobs, not just at boot.

## How the false claim was reached

Worth keeping, because the reasoning was valid right up to the last sentence.

The boot line reports `:enforced` and logs no divergence. Working backwards:

1. `observed_enforcement/0` can only return `:bypassed` or `:unknown`. It
   deliberately cannot assert `:enforced`.
2. `combine/2` returns `:enforced` only if one input is `:enforced`. Not the
   probe, by (1). So `claimed_enforcement/0`, the `pg_roles` attribute read.
3. `report_divergence/2` stays silent only when the signals agree or either
   abstains. `:bypassed` vs `:enforced` would have logged `DISAGREE`, and did
   not.

That correctly yields `observed = :unknown, claimed = :enforced`. **Every step
above still holds.**

The error was the next sentence: _"Probe `:unknown` means no tenant table
returned a row."_ The doc even listed `:unknown` as three-way ambiguous —
filtered, empty, or invisible-to-this-transaction — and then treated the prod
case as settled anyway. There was a fourth cause nobody enumerated: **the probe
never ran.** A derivation that concludes "the instrument read nothing" cannot
distinguish "it looked and saw nothing" from "it never looked", and this one
did not try.

Generalisable: `:unknown` from a diagnostic is not evidence about the system.
It is the absence of evidence, including about the diagnostic itself.

## What is settled

- **`engram_admin` has neither `rolsuper` nor `rolbypassrls`.** Confirmed from
  inside the app's own pool by 0.29.0's `claimed_enforcement/0`. Kills the
  "BYPASSRLS granted out of band" hypothesis.
- **Pre-flip, prod's app connection could read other tenants' rows.** Measured
  2026-09-25. Agreed with #1649.
- **Post-flip it cannot.** Adversarially verified as `engram_app`, above.
- **The difference is role membership, not role attributes or table flags.**
  See the comparison table. The `NO FORCE` migration theory is dead.

Withdrawn (from the pre-#1745 version of this doc):

- ~~"Prod is not currently leaking rows across tenants."~~ Never measured, and
  subsequently measured to be false.

## How to repeat the reading

1. Confirm the ECS rollout cycled BOTH tiers
   (`count by (role) (up{job="prometheus.scrape.engram_app"})` — see
   `prod-release-verification-gotchas.md`).
2. Confirm `transaction is not started` is ABSENT from the boot window. While
   it is present the probe is not running and the verdict is meaningless.
3. Read the boot line. A `DISAGREE` warning is a real `:bypassed`.

`Engram.Repo.tenant_tables/0` is the list the probe iterates, all eleven, not a
sample: `notes`, `chunks`, `attachments`, `api_keys`, `vaults`,
`user_agreements`, `onboarding_actions`, `crdt_update_log`, `note_links`,
`vault_index_states`, `vault_index_update_log`.

## Still open

Not the mechanism — see the comparison table; that is settled enough to have
acted on. What remains:

- **8 rows in `vault_index_states` still carry legacy AAD** (`dek_version < 2`).
  Every other encrypted table is uniformly v2. Harmless while the empty-AAD
  fallback exists — **do not retire that fallback until these are rebound.**
- **220 prod notes have NULL `path_ciphertext`.** They are skipped by every
  backfill (no path means no basename to HMAC, no doc to rebuild), so they show
  up forever as residual `basename_hmac IS NULL` and `crdt_head IS NULL`. When
  measuring backfill completeness, filter `AND path_ciphertext IS NOT NULL` or
  you will chase a number that cannot reach zero.
- **DEK rotation has never run in prod.** All users sit at `dek_version = 1`
  with no rotation locks held, so the "flipped `users.dek_version` while
  sweeping nothing" corruption class never occurred. Re-audit before the first
  real rotation.

## Failed approaches / gotchas

Three traps for anyone touching the probe. All cost real time.

- **`mode: :savepoint` is not a safe default.** It is only valid nested. Decide
  it at call time from `Repo.in_transaction?/0`. Passing it unconditionally
  fails outermost and, because the failure maps to a legitimate-looking verdict,
  fails silently.
- **A sandboxed test cannot exercise transaction-mode behaviour.** `DataCase`
  holds a transaction open, so everything is nested. Testing this needs
  `Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)` —
  `test/engram/repo/tenancy_guard_outermost_test.exs`. That test writes NOTHING
  on purpose: an earlier version inserted fixtures to assert `:bypassed` end to
  end, the cleanup could not cascade past `notes_user_id_fkey`, and the leftover
  rows broke unrelated tests in the same run. A non-sandbox test that writes is
  a contaminator.
- **`pg_class.reltuples` cannot disambiguate "filtered" from "empty".** A
  table-wide, NON-transactional statistic, so under the sandbox it reports the
  whole table while the connection sees only its own uncommitted rows. Reads as
  `:enforced` on a database enforcing nothing. Passed locally, turned CI red.
- **`$1::regclass` RAISES.** Postgrex infers an `oid` parameter from the cast
  and raises `ArgumentError` rather than returning `{:error, _}`. Error handling
  that only matches error tuples never catches it. Use `$1::text::regclass`.

## Operational consequence

`OrphanSweep` ran successfully for the first time in prod's history at
2026-09-25 05:00 UTC, immediately after the flip:

```
scanned Qdrant points:  25,667   candidates=0
probed chunk points:    25,663   missing=0
complete: 0 points, 0 users, 0 prefixes, 0 notes flagged
```

Zero deletions, and Qdrant/Postgres in sync to within 4 rows. Before #1747 the
same run would have diffed those 25,667 points against an empty set, because the
authority reads ran on the app pool. Measured contrast on the live database:

```
count(*) from chunks   as engram_app (no tenant):  0
                       as engram_admin:            25,666
```

The four historical `{:error, :tenancy_unsafe}` discards in `oban_jobs` are the
gate correctly refusing before any of this landed.

## References

- `lib/engram/repo/tenancy_guard.ex` (probe, `probe_opts/0`, `combine/2`)
- `test/engram/repo/tenancy_guard_outermost_test.exs` (the non-sandbox shape)
- `lib/engram/repo.ex` (`tenant_tables/0`, `maintenance/0`)
- `docs/context/database-schema-rls.md` (policies, `Repo.with_tenant/2`)
- `docs/context/rls-enforcement-testing-traps.md` (testing RLS without a false green)
- `docs/context/migrations-force-rls-data-dml.md` (the `NO FORCE` pattern)
- `docs/context/rls-cutover-breaks-api-key-auth.md` (the discovery policy; note
  its "prod was never affected" line describes the pre-flip world)
- `lib/engram/workers/orphan_sweep.ex` (`maintenance_repo/0`, the #1746 fix)
- `engram-app/Engram` PRs #1745, #1747 · issues #1726, #1649, #1746, #1354,
  #1357, #1739
- `engram-app/engram-infra` PRs #1238 (credential), #1243 (the prod flip),
  #1248 (staging parity)
