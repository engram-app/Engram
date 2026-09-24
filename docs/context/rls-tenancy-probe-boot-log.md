# Context Doc: Reading the RLS tenancy probe's boot log

_Last verified: 2026-09-24_

## Status

Current. `Engram.Repo.TenancyGuard`'s behavioural probe shipped in 0.30.0 and
was read off SaaS prod the same day.

## What This Is

What the probe measured on prod, and how to recover that result from the boot
log, which does not state it directly.

The probe's design, and why it asks Postgres to demonstrate enforcement rather
than describe itself, is in the moduledoc of `lib/engram/repo/tenancy_guard.ex`.
This doc is only about the prod reading and how to repeat it.

## The measurement

**On prod, 2026-09-24 ~06:51 UTC (task definitions `engram-saas-prod:169`,
`engram-worker-prod:20`), the probe saw ZERO rows across all eleven tenant
tables with `app.current_tenant` set to the all-zeros UUID.**

All eleven, not a sample. `Engram.Repo.tenant_tables/0` is the list the probe
iterates: `notes`, `chunks`, `attachments`, `api_keys`, `vaults`,
`user_agreements`, `onboarding_actions`, `crdt_update_log`, `note_links`,
`vault_index_states`, `vault_index_update_log`.

## How to read the boot log

The line reports `:enforced` and there is no divergence warning. Neither
statement says "the probe saw nothing", so work backwards through
`tenancy_guard.ex`:

1. `observed_enforcement/0` can only return `:bypassed` or `:unknown`. It
   deliberately cannot assert `:enforced` (seeing no rows has three causes;
   seeing a forbidden row has one).
2. `combine/2` returns `:enforced` only if one of its two inputs is
   `:enforced`. It was not the probe, by (1). So it was
   `claimed_enforcement/0`, the `pg_roles` attribute read.
3. `report_divergence/2` stays silent in exactly two cases: the two signals
   agree, or either one abstains with `:unknown`. `:bypassed` against
   `:enforced` would have logged `DISAGREE` at warning severity, and did not.

The only combination that produces "reports `:enforced`, logs no divergence" is
`observed = :unknown, claimed = :enforced`. Probe `:unknown` means no tenant
table returned a row.

## Why this matters

It is the opposite of `engram-app/Engram#1649`, which watched the same role
return all 3,602 `notes` rows with a tenant verifiably set. It agrees with
#1354 / #1357.

Two things are now settled that were not:

- **`engram_admin` has neither `rolsuper` nor `rolbypassrls`.** Confirmed from
  inside the app's own pool by 0.29.0, which kills the "BYPASSRLS granted out
  of band" hypothesis.
- **Prod is not currently leaking rows across tenants.** Measured, rather than
  inferred from role attributes.

## The caveat to keep

Probe `:unknown` is formally three-way ambiguous: the policy filtered us, the
table is empty, or the rows exist but are invisible to this transaction. Prod
has neither empty tenant tables nor a sandbox, so filtering is the live
explanation.

Strong evidence, not proof. The probe is built to make only the positive claim
(`:bypassed`) with confidence, and that asymmetry is deliberate.

## Still unexplained

#1649's observation. Either something changed between 09-16 and 09-24, or that
read was conditioned on something nobody isolated.

The most checkable remaining candidate is a per-table `NO FORCE ROW LEVEL
SECURITY` window from an interrupted migration. Ten migrations in
`priv/repo/migrations` use that pattern (see
`docs/context/migrations-force-rls-data-dml.md`). Compare `relrowsecurity` and
`relforcerowsecurity` across the eleven tables before looking anywhere else.
The probe now covers every tenant table specifically so that state cannot hide
again.

## Failed approaches / gotchas

Two traps for anyone touching the probe. Both cost real time.

- **`pg_class.reltuples` cannot disambiguate "filtered" from "empty".** It was
  an attempt to rule out the empty-table case so the probe could assert
  `:enforced`. It is a table-wide and NON-transactional statistic, so under the
  Ecto sandbox it reports the whole table while the connection sees only its
  own uncommitted rows. That reads as `:enforced` on a database enforcing
  nothing. It passed locally and turned CI red.
- **`$1::regclass` RAISES.** Postgrex infers an `oid` parameter from the cast
  and raises `ArgumentError` rather than returning `{:error, _}`. Error
  handling that only matches error tuples never catches it. Use
  `$1::text::regclass`.

## Operational consequence

`enforced?/0` stayed true, so `Engram.Workers.OrphanSweep` continued to refuse
to run, which is what #1739 guarantees. The probe result makes that refusal
correct rather than over-cautious.

It also moves `MAINTENANCE_DATABASE_URL` from a formality to the real unblock
for Phase 2.

## References

- `lib/engram/repo/tenancy_guard.ex` (probe, `combine/2`, `report_divergence/2`)
- `lib/engram/repo.ex` (`tenant_tables/0`, `maintenance/0`)
- `docs/context/database-schema-rls.md` (policies, `Repo.with_tenant/2`)
- `docs/context/rls-enforcement-testing-traps.md` (testing RLS without a false green)
- `docs/context/migrations-force-rls-data-dml.md` (the `NO FORCE` pattern)
- `engram-app/Engram` issues #1726, #1649, #1354, #1357, #1739
