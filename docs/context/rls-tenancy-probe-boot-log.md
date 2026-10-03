# Context Doc: Reading the RLS tenancy probe's boot log

_Last verified: 2026-10-03_

## Status

Prod and staging both enforce RLS at the database layer since 2026-09-25
(engram-infra#1243 prod, #1248 staging: `DATABASE_URL` is `engram_app`, plus a
maintenance pool). Both log `RLS enforced; maintenance pool configured` at
boot. This doc is the runbook for re-reading `Engram.Repo.TenancyGuard`, plus
the traps in the probe itself.

## How to repeat the reading

1. Confirm the ECS rollout cycled BOTH tiers
   (`count by (role) (up{job="prometheus.scrape.engram_app"})`, see
   `deploy-prod.md`).
2. Confirm `DBConnection.TransactionError: transaction is not started` is
   ABSENT from the boot window. Through 0.30.0 that line preceded every boot
   report because the probe never ran (#1745); while it is present the verdict
   is meaningless.
3. Read the boot line. A `RLS role attributes and observed behaviour DISAGREE`
   warning is a real `:bypassed`.

The probe iterates `Engram.Repo.tenant_tables/0` (all 12 tenant tables).

`:unknown` from the probe is the absence of evidence, including about the
probe itself. It is a legitimate verdict on an empty install, `combine/2`
falls back to the `pg_roles` attribute answer, and `report_divergence/2` stays
silent. That is how "the probe never ran" read as "enforced" until 0.31.0.

## Adversarial verification recipe

Do not trust a log line alone. Through the SSM bastion, as the real
`engram_app` credential:

```
no tenant set:           every tenant table -> 0 rows (except api_keys, see below)
as tenant A:             only A's rows
as A, read B:            0
as A, UPDATE/DELETE B:   0 rows affected
as A, INSERT owned by B: ERROR new row violates row-level security policy
as A, INSERT owned by A: INSERT 0 1   <- control; without it a role that rejects
                                         everything passes every line above
SET ROLE engram_admin / DISABLE RLS / CREATE POLICY: denied
```

`api_keys` returns rows with no tenant set by design (`api_keys_discovery`,
see `rls-cutover-breaks-api-key-auth.md`).

## What the 2026-09-25 measurement settled

- `engram_admin` (RDS master) has neither `rolsuper` nor `rolbypassrls`, yet
  pre-flip it read other tenants' rows (`count(*) from notes` with no tenant:
  3,602, #1649). Staging's `engram_app`, with identical attributes and FORCE
  flags but no role memberships, read 0. The difference is role membership
  (`rds_superuser` etc.), not attributes or table flags. Which membership does
  it was never pinned down (#1726).
- So "attributes say enforced" is not proof. Only the behavioural probe or the
  recipe above is.

## Still open

- **8 rows in `vault_index_states` still carry legacy AAD** (`dek_version < 2`).
  Harmless while the empty-AAD fallback exists. **Do not retire that fallback
  until these are rebound.**
- **220 prod notes have NULL `path_ciphertext`.** Every backfill skips them, so
  they stay as residual `basename_hmac IS NULL` / `crdt_head IS NULL`. Filter
  `AND path_ciphertext IS NOT NULL` when measuring backfill completeness.
- **DEK rotation has never run in prod** (all users `dek_version = 1`).
  Re-audit before the first real rotation.

## Probe traps

- **`mode: :savepoint` is not a safe default.** It is only valid nested; every
  production caller (boot `init/1`, the `OrphanSweep` and `CrdtBloatSweep`
  jobs) is outermost, so it failed with `transaction is not started` and the
  catch-all mapped that to `:unknown`. Decide the mode at call time from
  `Repo.in_transaction?/0` (`probe_opts/0`).
- **A sandboxed test cannot exercise transaction-mode behaviour.** `DataCase`
  holds a transaction open, so everything is nested. Use
  `Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)`, as in
  `test/engram/repo/tenancy_guard_outermost_test.exs`. That test writes
  NOTHING on purpose: a non-sandbox test that writes leaves rows that break
  unrelated tests.
- **`pg_class.reltuples` cannot tell "filtered" from "empty".** It is a
  table-wide, non-transactional statistic, so under the sandbox it reads as
  `:enforced` on a database enforcing nothing.
- **`$1::regclass` RAISES.** Postgrex infers an `oid` parameter and raises
  `ArgumentError` instead of returning `{:error, _}`. Use `$1::text::regclass`.

## References

- `lib/engram/repo/tenancy_guard.ex` (probe, `probe_opts/0`, `combine/2`)
- `test/engram/repo/tenancy_guard_outermost_test.exs`
- `database-schema-rls.md`, `maintenance-db-role.md`, `rls-enforcement-testing-traps.md`
- `engram-app/Engram` #1745, #1747, #1649, #1726
