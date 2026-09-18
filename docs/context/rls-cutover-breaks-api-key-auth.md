# Context Doc: RLS cutover breaks API-key auth (`invalid_key` on keys that exist)

_Last verified: 2026-09-18 (measured on staging)_

## Status

Live bug on staging. Prod is unaffected TODAY only because prod still connects
as its migrator role (BYPASSRLS). Fix proposed, not approved at time of writing.

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

## Recommended fix

Treat `api_keys` as an identity/credential table and drop it from the tenant
policy set. That is already the established treatment for `users`,
`refresh_tokens`, `oauth_clients` and `device_authorizations`, none of which
carry a policy.

Security cost is low. The row holds only a SHA256 `key_hash`, `name`, `user_id`
and timestamps, so reading another user's row does not let you authenticate:
you would need the hash preimage. Per-user scoping of `list_api_keys/1` and
`revoke_api_key/2` is already enforced by explicit `user_id` predicates.

### Changing the policy set is a 4-place edit

All four move together or tests fail:

1. A migration dropping the policy and FORCE RLS on `api_keys`.
2. `@tenant_tables` in lib/engram/repo.ex:16.
3. `priv/repo/structure.sql` (lines ~64 and ~1639 reference `api_keys` FORCE
   RLS and the policy).
4. docs/context/database-schema-rls.md, which says "Eleven tables carry FORCE
   ROW LEVEL SECURITY" and lists `api_keys` in several places.

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
