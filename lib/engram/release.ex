defmodule Engram.Release do
  @moduledoc """
  DB release tasks for production (no Mix available in release).

  Two layers, run in order from `/entrypoint.sh`:

    1. `prepare_database/0` — idempotent cluster-level bootstrap.
       Creates the `engram_app` low-privilege role and wires
       DEFAULT PRIVILEGES so future-created tables/sequences auto-grant
       to it. Runs as the connecting role (typically the cluster
       master). Cluster-scoped concerns belong here, not in Ecto
       migrations — migrations stay pure schema and don't bake in
       env-specific role names.

    2. `migrate/0` — runs Ecto migrations. The baseline migration
       assumes `engram_app` already exists (prepare_database created
       it) so its GRANT statements resolve.

  Both tasks are invoked from `entrypoint.sh`:

      /app/bin/engram eval "Engram.Release.prepare_database()"
      /app/bin/engram eval "Engram.Release.migrate()"

  Local dev / CI reach the same code path via the `ecto.setup` Mix
  alias (`mix.exs`).
  """

  @app :engram

  # NOINHERIT + LOGIN matches the historical baseline shape (preserved
  # for envs that rely on `engram_app` connecting directly).
  # PASSWORD intentionally absent — privilege separation (app
  # DATABASE_URL using engram_app creds) is a separate concern wired
  # via DATABASE_URL itself; this task only guarantees the role
  # exists.
  @create_engram_app_role_sql """
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
      CREATE ROLE engram_app NOINHERIT LOGIN;
    END IF;
  END
  $$;
  """

  @grant_schema_usage_sql "GRANT USAGE ON SCHEMA public TO engram_app;"

  # DEFAULT PRIVILEGES are bound to the role that creates the object.
  # CURRENT_USER means the rule applies to whichever migrator role is
  # running this task — portable across AWS (engram_admin), FastRaid
  # (engram), and local dev (cluster superuser). Without this, every
  # new migration would need explicit GRANT statements to engram_app.
  @default_priv_tables_sql """
  ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO engram_app;
  """

  @default_priv_sequences_sql """
  ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT SELECT, USAGE ON SEQUENCES TO engram_app;
  """

  @doc """
  Idempotent cluster bootstrap. Run BEFORE `migrate/0`.

  Creates the `engram_app` role and configures DEFAULT PRIVILEGES so
  the connecting role's future objects auto-grant CRUD on tables +
  SELECT/USAGE on sequences to `engram_app`. Existing objects are
  granted explicitly by the baseline migration's structure.sql dump.

  Requires the connecting role to have CREATEROLE + GRANT privileges.
  On AWS RDS this means the master user (`engram_admin`); locally /
  on FastRaid it's the cluster superuser.

  Safe to re-run: every statement is naturally idempotent (`IF NOT
  EXISTS` guard on role create, DEFAULT PRIVILEGES on the same target
  collapses, GRANT USAGE is no-op when already granted).
  """
  def prepare_database do
    _ = load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &do_prepare_database/1)
    end

    :ok
  end

  def migrate do
    _ = load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    _ = load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp do_prepare_database(repo) do
    repo.query!(@create_engram_app_role_sql, [])
    repo.query!(@grant_schema_usage_sql, [])
    repo.query!(@default_priv_tables_sql, [])
    repo.query!(@default_priv_sequences_sql, [])
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
