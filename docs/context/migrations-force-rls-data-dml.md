# Data migrations vs FORCE ROW LEVEL SECURITY — silent 0-row no-op

_Last verified: 2026-10-03_

## The trap

Raw DML (`execute("UPDATE/DELETE/INSERT ...")`) in a migration against a
tenant-scoped table (`Engram.Repo.tenant_tables/0`) runs with no
`app.current_tenant`. Tenant tables carry `FORCE ROW LEVEL SECURITY`, so for a
migrator that does not bypass RLS the tenant policy filters every row: the DML
"succeeds" on 0 rows, no error, migration marked applied.

Whether prod's migrator bypasses is not something to rely on. `engram_admin`
(RDS master) has neither SUPERUSER nor BYPASSRLS, yet was measured reading past
FORCE RLS on 2026-09-25, attributed to its role memberships with the mechanism
unpinned (#1726, `rls-tenancy-probe-boot-log.md`). Any role or RDS change can
flip it. Use the pattern below regardless.

**Dev/CI mask the bug completely**: their Docker `POSTGRES_USER` is a
superuser, which bypasses RLS regardless of FORCE, so the migration works
there and CI stays green. First hit: `20260629250000_clear_v1_crdt_state_migrate.exs`
(v1 CRDT purge), caught in the 2026-07-02 audit before it reached a
`release-v*` tag.

## The pattern

Drop the owner-applies flag for the migration transaction, verify, restore:

```elixir
execute("ALTER TABLE notes NO FORCE ROW LEVEL SECURITY")
execute("UPDATE notes SET ...")
# rowcount / invariant assertion via DO $$ ... RAISE EXCEPTION ... $$
execute("ALTER TABLE notes FORCE ROW LEVEL SECURITY")
```

Why this is safe:

- Owners bypass RLS *unless* FORCE — `NO FORCE` restores the owner bypass.
- `ALTER TABLE` takes ACCESS EXCLUSIVE, so app queries can't run during the
  unforced window; migrations run in a transaction, so rollback restores
  FORCE on any failure.
- Always add a fail-loud verification (DO-block count + `RAISE EXCEPTION`)
  **while still unforced**, so a partial purge can't slip through silently.
- Requires the migrator to be the table owner (it is — it ran the CREATEs).
  `SET row_security = off` is NOT equivalent: for a non-BYPASSRLS role it
  errors instead of bypassing (loud, but the migration then can't run).

## The guard

`test/lint/migration_rls_lint_test.exs` fails any migration with tenant-table
DML that lacks the NO FORCE/FORCE pair (allowlist with justification for
legitimate exceptions). Sibling of `raw_sql_tenant_table_lint_test.exs`,
which covers `lib/` but not `priv/repo/migrations/` — that gap is how the
first instance slipped through.

## Dead ends

- "DELETE respects RLS" as a *feature* in a migration comment — that framing
  was the bug: respecting RLS in a tenant-less session means seeing nothing.
- Testing the fix on dev/CI proves nothing about prod (superuser bypass).
  Trust the pattern + the loud assertion, not a green local run.
