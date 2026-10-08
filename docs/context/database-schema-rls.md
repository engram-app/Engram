# Context Doc: Database Schema & RLS

_Last verified: 2026-10-03_

## What This Is

The PostgreSQL schema model (encrypted at rest, multi-vault, uuidv7 PKs), the
Row-Level Security policy set, the DB roles, and the Ecto-side tenant model.
For column-level shape read the Ecto schemas and `priv/repo/migrations/`, not
`priv/repo/structure.sql`: that file is the 2026-06-02 baseline dump and is
missing every column and table added since.

## Schema: key facts

- **PKs are `uuid DEFAULT uuidv7()`**, all FKs `uuid`. See
  `pg18-uuidv7-prod-crashloop-2026-06-11.md` for why the baseline is
  wreck-and-recreate.
- **No plaintext note/vault fields.** `notes`/`attachments`/`vaults` store
  `*_ciphertext` + `*_nonce` (AES-GCM, AAD-bound, per-user DEK in
  `users.encrypted_dek`), plus a keyed `*_hmac` blind index for anything that
  must be looked up or uniquely indexed (path, folder, tags, basename, type,
  vault name, vault slug). See `encryption-operations.md`.
- **Multi-vault.** `notes`/`chunks`/`attachments` are scoped by both `user_id`
  and `vault_id`. API keys reach vaults through `api_key_vaults`.
- **Chunks are hybrid.** Postgres `chunks` holds boundaries/positions; Qdrant
  holds vectors and contextualized text.

## RLS policy set

The authority is `Engram.Repo.@tenant_tables` (`lib/engram/repo.ex:16`), 12
tables: `notes chunks attachments api_keys vaults user_agreements
onboarding_actions crdt_update_log note_links vault_index_states
vault_index_update_log account_exports`. `repo_tenant_guard_test.exs` pins it
against live `pg_class.relrowsecurity`. Do not audit against `structure.sql`:
it shows only the first six, the rest got RLS in their own migrations.

Each tenant table has ENABLE + FORCE RLS and three policies:

```sql
CREATE POLICY tenant_isolation_<t> ON <t>
  USING      ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
  WITH CHECK ((user_id)::text = (SELECT current_setting('app.current_tenant', true)));
CREATE POLICY maintenance_all ON <t> TO engram_maintenance USING (true) WITH CHECK (true);
```

plus, on `api_keys` only, `api_keys_discovery` (FOR SELECT while no tenant is
set, `TO engram_key_lookup` since #1867) so key lookup works. Only
`validate_api_key/1` switches to that role; plain `engram_app` with no tenant
sees zero keys. See `rls-cutover-breaks-api-key-auth.md` and
`maintenance-db-role.md`.

`subscriptions` is per-user but NOT yet in the set (#1758 open). Its access is
already routed for an enforced policy (#1771).

## DB roles

| Role | Used by | RLS |
|---|---|---|
| `engram_app` | app pool (`DATABASE_URL`); `with_tenant/2` also does `set_config('role','engram_app',true)` | enforced |
| `engram_admin` (RDS master) | migrations, `prepare_database` (`MIGRATOR_DATABASE_URL`) | not a superuser, but measured reading past FORCE RLS on prod (role memberships, #1726) |
| `engram_maintenance` | `Repo.Maintenance` pool (`MAINTENANCE_DATABASE_URL`) | sees all rows via `maintenance_all` |

Roles, grants and passwords are created by `Engram.Release.prepare_database/0`
(`lib/engram/release.ex`). Dev, CI and test connect as the superuser `engram`,
which bypasses RLS even under FORCE, so a green suite proves nothing about
enforcement (see `rls-enforcement-testing-traps.md`).

## Ecto tenant model

The failure mode: a tenant-table query with no tenant set does not error.
Under enforced RLS, SELECT returns 0 rows, UPDATE/DELETE report 0 affected,
and only INSERT raises (42501).

- **`Repo.with_tenant(user_id, fun)`** opens a transaction, sets
  `app.current_tenant` and the `engram_app` role in one `set_config(..., true)`
  round trip, and resets both on exit (so a completed block does not leak its
  tenant into an enclosing transaction, #1761). Nested same-tenant calls run
  `fun` directly; a different tenant raises. Returns `{:ok, result}`;
  `with_tenant!/2` returns the bare result. See `with-tenant-return-wrapping.md`.
- **`Repo.prepare_query/3`** raises `Engram.TenantError` (after a
  `tenant_guard_violation` metric + error log) when a tenant table is queried
  with no tenant, no `cross_tenant/1` block and no `skip_tenant_check: true`.
  Raises in every env.
- **Context functions and Oban workers** take `user_id` and call `with_tenant`
  themselves. The process-dict tenant is not inherited by spawned tasks.

## `skip_tenant_check`, `cross_tenant/1`, `maintenance()`

- `skip_tenant_check: true` (per query) and `Repo.cross_tenant/1` (block) mean
  the same thing and emit the same `:tenant_check_skipped` telemetry. Both
  suppress ONLY the `prepare_query/3` tripwire. Neither sets Postgres state,
  so neither is a scope: under enforced RLS the query is still filtered, and
  three of four verbs fail silently.
- Work that genuinely spans tenants goes through `Repo.maintenance()`. It is a
  separate, RLS-exempt pool where `MAINTENANCE_DATABASE_URL` is set (prod and
  staging); on self-host it resolves to `Engram.Repo`. If a single tenant is
  known, use `with_tenant` instead.
- There is no lexical "is it scoped?" lint, because scoping is often supplied
  by a caller's closure far from the call site (e.g. `user_dek_rotation.ex`
  `TenantSweep.each_batch`). Instead `test/lint/skip_tenant_check_inventory_test.exs`
  is a per-file count ratchet (adding a site fails until the count is updated),
  and `tenant_enumeration_lint_test.exs` covers only the `from(...)`
  enumerate-by-`user_id` shape.
- Mixed-path trap: a function scoped from one caller and unscoped from others
  reads as correct in isolation. Scope inside the function itself (the fix for
  `links.ex` `prefetch_candidates/4`, which was reached unscoped from five
  paths).

## References

- `lib/engram/repo.ex`: `@tenant_tables`, `with_tenant/2`, `cross_tenant/1`, `maintenance/0`, `prepare_query/3`
- `lib/engram/repo/maintenance.ex`, `lib/engram/repo/tenancy_guard.ex`
- `lib/engram/release.ex`: role creation and grants
- `rls-enforcement-testing-traps.md`, `maintenance-db-role.md`, `rls-tenancy-probe-boot-log.md`, `migrations-force-rls-data-dml.md`
