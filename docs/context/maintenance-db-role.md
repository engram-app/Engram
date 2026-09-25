# Context Doc: The `engram_maintenance` role (maintenance pool credential)

_Last verified: 2026-09-25_

## Status

Shipped in Engram#1774 (role, grants, policies). The credential is wired by
engram-infra#1259 (staging) and #1260 (prod). Before those, SaaS prod's
`MAINTENANCE_DATABASE_URL` connected as the RDS master `engram_admin`
(engram-infra#1243). That worked, but it gave every cross-tenant sweep
CREATEROLE and DDL on the schema.

## Why it is not a BYPASSRLS role

It cannot be one on RDS. The master user (`engram_admin`) has CREATEROLE but
is not a superuser, and since PG16 a CREATEROLE role can only grant attributes
it holds itself. `engram_admin` reads `rolbypassrls = false` (measured from
inside the app pool by `TenancyGuard`), so `CREATE ROLE ... BYPASSRLS` fails.
engram-infra's `docs/context/prod-db-readonly-access.md` hit the same wall for
`engram_audit_ro`.

Copying `engram_admin`'s memberships (`rds_superuser`, `pg_read_all_data`,
`pg_write_all_data`) onto a new role is not an alternative. They are at least
as broad as the master, and which of them actually lets `engram_admin` read
past RLS was never pinned down (Engram#1726).

## The pattern: a role-scoped permissive policy per tenant table

```sql
CREATE POLICY maintenance_all ON <table> TO engram_maintenance
  USING (true) WITH CHECK (true);
```

Permissive policies OR together. For `engram_maintenance` this makes every row
visible and writable; for every other role the `TO` clause means the policy
does not exist. The role itself has no attributes at all: NOINHERIT LOGIN, no
SUPERUSER/BYPASSRLS/CREATEROLE/CREATEDB, no memberships, DML-only grants.

Where each piece lives:

- Role, grants, default privileges, password: `Engram.Release.prepare_database/0`,
  which runs before every migrate (entrypoint, `ecto.setup`, `test` alias, CI).
- Existing tables are granted by `GRANT ... ON ALL TABLES` in
  `prepare_database`, because the role postdates the baseline dump. Future
  tables are covered by `ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER`.
- Password: `ENGRAM_MAINTENANCE_DB_PASSWORD`, applied as a SCRAM verifier on
  every boot, same code as `ENGRAM_APP_DB_PASSWORD`.
- Policies: migration `20260925150000_add_maintenance_all_policies_expand.exs`.
  It ALSO creates the role if missing, with the same guarded statement and
  attributes. A migration must apply on top of the previous release's
  bootstrap: the n1-compat gate runs the previous tag's `prepare_database`
  (which predates this role) and then this migration, and
  `CREATE POLICY ... TO` an unknown role fails with 42704. Both creators are
  idempotent in either order. A role the migration creates has no grants and
  no password until `prepare_database` runs. `down/0` drops only the
  policies; `prepare_database` owns the role.

**Every new tenant table needs its own `maintenance_all`,** added in the same
migration that enables RLS on it. Without it the maintenance pool reads zero
rows from that table and every sweep over it reports success while doing
nothing. `Engram.Repo.MaintenanceRoleTest`'s test "every tenant table carries
maintenance_all, permissive, ALL, TO engram_maintenance only" fails until the
policy exists for everything in `Repo.tenant_tables/0`.

## Rollout hazard: a role without its policies

Never point `MAINTENANCE_DATABASE_URL` at `engram_maintenance` on a database
where the role exists but the policies do not. Every read is then filtered to
zero rows with no error, and `OrphanSweep` diffs Qdrant against an empty chunk
set, so every Qdrant point looks orphaned and gets deleted irreversibly. The
role and the policies ship in the same release, so this needs a partial
deploy to occur. The runbook checks before the infra flip anyway:

```sql
SELECT count(*) FROM pg_policy WHERE polname = 'maintenance_all';  -- one per tenant table
```

An image OLDER than #1774 is the safe failure: the role does not exist and the
pool fails to connect, which is loud.

## Why both ECS tiers keep `MAINTENANCE_DATABASE_URL`

Every `Repo.maintenance()` caller is an Oban job, so the web tier never uses
the pool. It still gets the variable. `Engram.Repo.TenancyGuard` runs on web
too, and without the variable it logs a `category=boot` ERROR ("RLS is
ENFORCED for this connection, but no maintenance pool is configured") and
emits `tenancy_misconfigured` on every web boot. The prod boot alert no longer
excludes that line. Also, with `oban_worker_enabled = false` the single web
task runs every queue. Worker-only needs a backend change first (a
role-aware TenancyGuard). The cost of keeping it is one idle connection per
web task (`MAINTENANCE_POOL_SIZE=1`).

## Test trap: `has_table_privilege` with a privilege list

```sql
SELECT has_table_privilege('engram_maintenance', 'notes', 'SELECT,INSERT,UPDATE,DELETE');
```

returns true if ANY of the listed privileges is held, not all. A SELECT-only
grant passed the first version of the grants test; mutation testing caught
it. Check one privilege per call.

## Merge-order coupling

Tables that join the tenant set in parallel PRs must also get
`maintenance_all`. Whichever PR merges second adds it:

- `account_exports`: Engram#1759
- `subscriptions`: Engram#1771 / #1758

The coverage test above fails on that second branch until it does.

## Verifying a deployment

From the maintenance pool:

```sql
SELECT current_user, rolbypassrls, rolsuper FROM pg_roles WHERE rolname = current_user;
-- engram_maintenance | f | f
```

Then the next `orphan_sweep` / `crdt_bloat_sweep` must not log
`refusing to run`, `crdt_bloat_sweep notes=` must match the previous run
(not 0), and `qdrant_points_swept` should stay around 0.

## Related

- `lib/engram/repo/maintenance.ex`: the pool and its rules
- `docs/context/rls-tenancy-probe-boot-log.md`: the RLS cutover
- `docs/context/rls-enforcement-testing-traps.md`: testing under a dropped role
- `test/engram/repo/maintenance_role_test.exs`
