# Context Doc: Reading the RLS tenancy probe's boot log

_Last verified: 2026-09-24_

## Status

**RETRACTED AND SUPERSEDED.** An earlier version of this doc claimed the probe
measured prod on 2026-09-24. It did not. The probe never executed in production
at all, and this doc's headline finding was an inference, not a measurement.

The bug is fixed (`TenancyGuard.probe_opts/0`), but the fix has not reached prod
yet. **There is currently no prod reading.** Re-measure once a release carrying
it has rolled.

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

## What is still settled

One of the two prior conclusions survives, because it came from a different
mechanism:

- **`engram_admin` has neither `rolsuper` nor `rolbypassrls`.** Confirmed from
  inside the app's own pool by 0.29.0's `claimed_enforcement/0`, which does not
  go through the broken transaction. This still kills the "BYPASSRLS granted out
  of band" hypothesis.

Withdrawn:

- ~~"Prod is not currently leaking rows across tenants."~~ Never measured.
  #1649's observation — the same role returning all 3,602 `notes` rows with a
  tenant verifiably set — stands unrebutted. Nothing here contradicts it, and
  nothing here agrees with #1354 / #1357 either.

## How to get a real reading

1. Ship a release containing `probe_opts/0` and confirm the ECS rollout cycled
   BOTH tiers (`count by (role) (up{job="prometheus.scrape.engram_app"})` —
   see `prod-release-verification-gotchas.md`).
2. Confirm the `transaction is not started` line is GONE from the boot window.
   While it is present the probe is still not running.
3. Then read the boot line and apply the derivation above. A `DISAGREE` warning
   at that point is a real `:bypassed` and means #1726 is live.

`Engram.Repo.tenant_tables/0` is the list the probe iterates, all eleven, not a
sample: `notes`, `chunks`, `attachments`, `api_keys`, `vaults`,
`user_agreements`, `onboarding_actions`, `crdt_update_log`, `note_links`,
`vault_index_states`, `vault_index_update_log`.

## Still unexplained

#1726 / #1649 in full. No progress was actually made on the mechanism; the
apparent progress was this artifact.

The most checkable candidate remains a per-table `NO FORCE ROW LEVEL SECURITY`
window from an interrupted migration. Ten migrations in `priv/repo/migrations`
use that pattern (see `docs/context/migrations-force-rls-data-dml.md`). Compare
`relrowsecurity` and `relforcerowsecurity` across the eleven tables.

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

Unchanged, and unchanged for the same reason as before: `enforced?/0` stayed
true, so `Engram.Workers.OrphanSweep` continued to refuse to run, which is what
#1739 guarantees. That refusal was correct — but on the strength of the
attribute answer alone, not the probe. The probe contributed nothing.

`MAINTENANCE_DATABASE_URL` remains the real unblock for Phase 2.

## References

- `lib/engram/repo/tenancy_guard.ex` (probe, `probe_opts/0`, `combine/2`)
- `test/engram/repo/tenancy_guard_outermost_test.exs` (the non-sandbox shape)
- `lib/engram/repo.ex` (`tenant_tables/0`, `maintenance/0`)
- `docs/context/database-schema-rls.md` (policies, `Repo.with_tenant/2`)
- `docs/context/rls-enforcement-testing-traps.md` (testing RLS without a false green)
- `docs/context/migrations-force-rls-data-dml.md` (the `NO FORCE` pattern)
- `engram-app/Engram` issues #1726, #1649, #1354, #1357, #1739
