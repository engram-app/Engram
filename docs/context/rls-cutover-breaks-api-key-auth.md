# Context Doc: RLS cutover breaks API-key auth (`invalid_key` on keys that exist)

_Last verified: 2026-09-18 (measured on staging)_

## Status

Live bug on staging, FIXED by adding a permissive `FOR SELECT` discovery policy
(see "The fix"). Prod was never affected, because prod still connects as its
migrator role (BYPASSRLS), and would have hit this at cutover.

## What This Is

Why every API-key authenticated request on staging returns 401 after the
staging app pool dropped from a superuser role to a restricted one, and what
changing the fix requires. `docs/context/database-schema-rls.md` describes the
policy set; `docs/context/rls-enforcement-testing-traps.md` covers testing it.
This doc is only about the credential-lookup path.

## The symptom

Every API-key authenticated request returns 401 with `reason: "invalid_key"`,
logged from `lib/engram_web/plugs/auth.ex:43`, for keys that demonstrably exist
in the database. Hits plugin sync, MCP clients and scripts.

Clerk JWT is a separate code path and was NOT proven either way: staging had no
authenticated Clerk traffic to judge by. Do not assume it is fine, and do not
assume it is broken.

## Root cause

`api_keys` is one of the 11 tables carrying `FORCE ROW LEVEL SECURITY` plus a
`tenant_isolation_api_keys` policy:

```sql
USING ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
```

`Engram.Accounts.validate_api_key/1` (lib/engram/accounts.ex:608-622) looks the
key up by `key_hash` inside `Repo.cross_tenant/1`. `cross_tenant/1`
(lib/engram/repo.ex:180) only sets a **process flag** that suppresses the
app-level `prepare_query/3` tripwire. It sets no Postgres session state, so the
policy still applies and the row is filtered out.

This read is a tenant **discovery**: `user_id` is the thing being looked up, so
there is nothing to scope by. No amount of `with_tenant` wrapping can fix the
call site.

## Why it surfaced now

engram-infra PR #1188 (commit bb5553e, 2026-09-16 17:07) dropped staging's app
pool credential from the superuser `engram` to the restricted `engram_app`.
Before that, every environment connected as its migrator role, which has
BYPASSRLS, so all 11 policies existed and never bit. The bug was latent, not
new. Prod will hit it the moment prod cuts over.

## Proof

In-app A/B via `docker exec engram-saas /app/bin/engram rpc`, same key, same
pool, same process:

| Probe | Result |
|---|---|
| A) app pool, NO tenant | `[[0]]` |
| B) app pool, WITH tenant | `[[1]]` |
| C) `validate_api_key/1` | `{:error, :invalid_key}` |
| D) `Engram.Repo.maintenance()` | `Engram.Repo` |

Corroborated at the DB level. `SET SESSION AUTHORIZATION engram_app; select
count(*) from api_keys` returns 0 with no tenant, 1 with the tenant set, and 4
as superuser.

## The maintenance pool is the WRONG fix

- `Engram.Repo.Maintenance`'s own moduledoc states the rule: "Separate
  credential, never the request path".
- `MAINTENANCE_POOL_SIZE` defaults to 2 (config/runtime.exs). Routing every
  authenticated API request through a 2-connection pool is a worse problem than
  the bug.
- `maintenance()` currently resolves to `Engram.Repo` anyway, because
  `MAINTENANCE_DATABASE_URL` is unset on staging. Moving the call site alone
  changes nothing.

## The fix

One permissive policy, in
`priv/repo/migrations/20260918120000_add_api_keys_discovery_policy.exs`:

```sql
CREATE POLICY api_keys_discovery ON api_keys FOR SELECT
  USING (coalesce((SELECT current_setting('app.current_tenant', true)), '') = '');
```

Permissive policies OR within a command and AND across commands, so a
`FOR SELECT` policy widens reads ONLY. INSERT still goes through
`tenant_isolation_api_keys`'s WITH CHECK; UPDATE and DELETE still go through
its USING. Nothing else changes: `@tenant_tables` keeps `api_keys` so the
`prepare_query/3` tripwire and four derived lints survive, `structure.sql`
needs no edit, and `validate_api_key/1` keeps its existing
`Repo.cross_tenant/1` wrapper.

The predicate is "no tenant is set" rather than `true`. Both fix auth, but
`true` surrenders read isolation entirely. Measured as `engram_app`:

| policy | no tenant (auth path) | inside `with_tenant` |
|---|---|---|
| no RLS at all | all rows | all rows |
| `USING (true)` | all rows | all rows |
| `USING (tenant unset)` | all rows | own rows only |

With a tenant set, a foreign INSERT still raises 42501 and cross-tenant
UPDATE/DELETE still report 0 rows. All four verbs were verified on a scratch
database before shipping.

## Rejected: dropping `api_keys` from the policy set

This was attempted first and abandoned after review. Treating `api_keys` as an
identity table (the established treatment for `users`, `refresh_tokens`,
`oauth_clients` and `device_authorizations`, none of which carry a policy) is
defensible in the abstract and is what most multi-tenant Postgres guidance
recommends. It is the wrong trade HERE because the outage was one filtered
SELECT, and dropping the policy also discards:

- the WITH CHECK guard on INSERT, which is the only verb RLS makes LOUD
  (42501); the others fail silently,
- the USING guard on UPDATE and DELETE,
- the `prepare_query/3` tripwire, since the drift test
  (`repo_tenant_guard_test.exs`) forces `@tenant_tables` to equal the live RLS
  set,
- four lints deriving from `Repo.tenant_tables/0`.

The compensating control offered for that version was `REVOKE UPDATE ON
api_keys FROM engram_app` — which protects a verb with zero callers, while the
verb that actually writes (INSERT) lost its only database-level guard. A CHECK
constraint cannot substitute: `current_setting()` is STABLE and CHECK requires
IMMUTABLE.

### If you ever DO change the policy set

Four places move together or tests fail:

1. A migration dropping the policy and FORCE RLS on `api_keys`.
2. `@tenant_tables` in lib/engram/repo.ex:16.
3. `priv/repo/structure.sql` (the `api_keys` FORCE RLS line and the policy).
4. docs/context/database-schema-rls.md, which counts the FORCE-RLS tables and
   lists `api_keys` in several places.

`test/engram/repo_tenant_guard_test.exs` is a drift guard asserting
`Repo.tenant_tables()` equals the live set of RLS-enabled tables read from the
schema, so it catches any partial change. Related lints deriving from
`Repo.tenant_tables/0`: test/lint/migration_rls_lint_test.exs,
test/lint/tenant_enumeration_lint_test.exs, test/engram/rls_policy_form_test.exs.

## Every `Repo.cross_tenant/1` call site (5)

Each bypasses the app guard but NOT the policy.

| Site | Note |
|---|---|
| lib/engram/accounts.ex:614 | this bug, the only one on the request path |
| lib/engram/indexing.ex:450 | |
| lib/engram/notes.ex:2376 | documented legacy worker bridge |
| lib/engram/workers/orphan_sweep.ex:328, :547 | by design; that worker already refuses with `{:error, :tenancy_unsafe}` when RLS is enforced without a maintenance pool |

## Two instrumentation gotchas measured the same session

- **`api_keys.last_used` is never written** by any code. It is only read, in
  lib/engram/connections.ex. Useless as a "was this key ever used" signal: all
  4 staging rows read NULL, including ones created in June and August.
- **Staging does not ship logs to Grafana Cloud Loki.** The Loki `env` label has
  only the value `prod`. Staging observability is `docker logs` on the FastRaid
  host, bounded by container uptime: a restart truncates the window.

## Staging access recipe

```bash
ssh root@10.0.20.214
# Postgres container
docker exec engram-saas-postgres psql -U engram -d engram
# App container (rpc probes)
docker exec engram-saas /app/bin/engram rpc '...'
```

To test as the restricted role without needing its password, run
`SET SESSION AUTHORIZATION engram_app;` from the superuser session.
