# Context Doc: RLS cutover breaks API-key auth (`invalid_key` on keys that exist)

_Last verified: 2026-10-03_

## What This Is

Why `api_keys` carries a permissive `api_keys_discovery` policy, and what
changing it requires. Without it, once an app pool drops off a
BYPASSRLS/superuser role (staging 2026-09-16, prod 2026-09-25), every API-key
request 401s with `reason: "invalid_key"` for keys that exist. Policy set:
`database-schema-rls.md`. Testing it: `rls-enforcement-testing-traps.md`.

## Root cause

`api_keys` is one of the 12 tables carrying `FORCE ROW LEVEL SECURITY` plus a
`tenant_isolation_api_keys` policy:

```sql
USING ((user_id)::text = (SELECT current_setting('app.current_tenant', true)))
```

`Engram.Accounts.validate_api_key/1` (lib/engram/accounts.ex) looks the
key up by `key_hash` inside `Repo.cross_tenant/1`. `cross_tenant/1`
(lib/engram/repo.ex) only sets a **process flag** that suppresses the
app-level `prepare_query/3` tripwire. It sets no Postgres session state, so the
policy still applies and the row is filtered out.

This read is a tenant **discovery**: `user_id` is the thing being looked up, so
there is nothing to scope by. No amount of `with_tenant` wrapping can fix the
call site.

## The maintenance pool is the WRONG fix

`Engram.Repo.Maintenance`'s own rule is "Separate credential, never the request
path", and it is a 1-2 connection pool. Routing every authenticated request
through it is worse than the bug.

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

Keep `20260918120000` out of any rollback runbook. Its `down/0` restores the
outage.


### #1867: scoped TO engram_key_lookup

The policy above had no `TO` clause, so it applied to every role: any
unscoped `engram_app` query (e.g. a join from `users` to `api_keys`) returned
every user's `key_hash`/`name`/`user_id`. Fixed in two releases:

1. Expand (`20261006160000`): NOLOGIN role `engram_key_lookup` with SELECT on
   `api_keys`; `engram_app` holds it `WITH INHERIT FALSE, SET TRUE`
   (`prepare_database/0`). `validate_api_key/1` reads the key under
   `SET LOCAL ROLE engram_key_lookup`, resets the role, then preloads the user.
2. Contract (`20261008041903`): `ALTER POLICY api_keys_discovery ... TO
   engram_key_lookup`. Must ship after (1): N-1 code reads as plain
   `engram_app` and would 401 every API key.

Because the membership is non-inherited, policies `TO engram_key_lookup` do
not apply to `engram_app` until it explicitly switches role. Pinned by
`test/engram/accounts_api_key_auth_rls_test.exs`.

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
api_keys FROM engram_app`, which protects a verb with zero callers, while the
verb that actually writes (INSERT) lost its only database-level guard. A CHECK
constraint cannot substitute: `current_setting()` is STABLE and CHECK requires
IMMUTABLE.

### If you ever DO change the policy set

Four places move together or tests fail:

1. A migration dropping the policies (`tenant_isolation_api_keys`,
   `api_keys_discovery`, `maintenance_all`) and FORCE RLS on `api_keys`.
2. `@tenant_tables` in lib/engram/repo.ex:16.
3. `priv/repo/structure.sql` (the `api_keys` FORCE RLS line and the policy).
4. docs/context/database-schema-rls.md, which counts the FORCE-RLS tables and
   lists `api_keys` in several places.

`test/engram/repo_tenant_guard_test.exs` is a drift guard asserting
`Repo.tenant_tables()` equals the live set of RLS-enabled tables read from the
schema, so it catches any partial change. Related lints deriving from
`Repo.tenant_tables/0`: test/lint/migration_rls_lint_test.exs,
test/lint/tenant_enumeration_lint_test.exs, test/engram/rls_policy_form_test.exs.
