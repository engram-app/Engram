defmodule Engram.Repo.Maintenance do
  @moduledoc """
  Second connection pool, for work that legitimately spans tenants.

  `Engram.Repo` connects as a role that RLS applies to (`engram_app` where the
  two-login split is deployed) and every query through it must name a tenant.
  A handful of jobs cannot: orphan reapers, expiry sweeps, and credential
  lookups where the user_id is the thing being *discovered*. Under RLS those
  queries do not fail — `SELECT` returns zero rows and `UPDATE`/`DELETE` report
  0 affected with no error — so a sweep that has been silently no-opping for
  weeks looks exactly like a sweep with nothing to do.

  This pool is the sanctioned way to run them. Two properties matter:

    * **No `prepare_query/3` override.** `Engram.Repo` carries an app-level
      tripwire that rejects an unscoped query against a tenant table, which is
      why ~250 call sites pass `skip_tenant_check: true` to opt out. That option
      only ever silenced the *app* guard; it set no Postgres session state and
      was never a scope, which is what made it such an effective disguise for
      the bug. Queries here need no such option, so the pool a caller reaches
      for is what declares cross-tenant intent — a choice that shows up in a
      diff, unlike a keyword buried at the end of a long query.

    * **Separate credential, never the request path.** The URL comes from
      `MAINTENANCE_DATABASE_URL` alone. Nothing in a web request may use this
      module — a rule currently held by review alone. There is no lint
      enforcing it yet, and this docstring previously claimed one existed,
      which is worse than claiming nothing.

  ## Which credential

  `engram_maintenance`, created by `Engram.Release.prepare_database/0`. It has
  no bypass attributes at all (no SUPERUSER, BYPASSRLS, CREATEROLE or
  CREATEDB, no role memberships) and DML-only grants. Its cross-tenant reach
  is one permissive `maintenance_all` policy per tenant table, scoped
  `TO engram_maintenance`, not BYPASSRLS, because RDS cannot grant that to a
  custom role (the master is CREATEROLE, not superuser). A new tenant table
  must add its own `maintenance_all`; `Engram.Repo.MaintenanceRoleTest` fails
  until it does, and until then this pool reads zero rows from that table.

  SaaS prod pointed this pool at the RDS master (`engram_admin`) from
  engram-infra#1243 until the dedicated role shipped. That worked, but it also
  handed every sweep CREATEROLE and DDL on the schema.

  ## Unconfigured is a supported state

  When `MAINTENANCE_DATABASE_URL` is unset this repo is never started and
  `Engram.Repo.maintenance/0` resolves to `Engram.Repo`. That is the *correct*
  configuration for self-host: one box, one operator, one tenant, connecting as
  a role that owns its own database. RLS has nothing to separate there, and
  demanding a second credential would be ceremony charged to the person least
  able to benefit from it.

  It is the wrong configuration for SaaS, where an unset variable means the
  sweeps are filtered to zero rows. `Engram.Repo.TenancyGuard` is what notices
  that at boot.

  ## Not in `:ecto_repos`

  Deliberate. `mix ecto.migrate` and `Engram.Release.migrate/0` walk that list,
  and this pool must never run DDL — it holds no migrator privileges and the
  schema has exactly one owner. It is started as a plain supervision child
  instead.
  """

  use Ecto.Repo,
    otp_app: :engram,
    adapter: Ecto.Adapters.Postgres
end
