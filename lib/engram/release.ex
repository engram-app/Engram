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

  require Logger

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

  @doc """
  One-shot, self-guarded baseline reset for the PG18 + UUIDv7 cutover.

  Background: the PG18/uuidv7 rework (#524) is a wreck-and-recreate baseline,
  not a data migration — the uuid schema only materialises by replaying
  `structure.sql` on an EMPTY schema. Prod's RDS was upgraded PG17→PG18
  *in-place* (engram-infra #476, `apply_immediately`) instead of taint+recreate,
  so it kept its legacy integer-PK tables while the baseline migration stayed
  marked applied. The app then crash-loops loading integer ids as `Ecto.UUID`
  (see `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`).

  This drops and rebuilds the schema so the uuid baseline replays. Guarded two
  ways so it can NEVER wipe a healthy DB:

    1. The entrypoint only invokes it when `ENGRAM_DB_RESET_BASELINE=true`.
    2. Self-disabling: it inspects `terms_versions.id`'s column type and no-ops
       unless that type is a legacy integer. Once the schema is uuid (or the
       table is absent), this returns `:ok` having touched nothing.

  Pre-launch one-shot. Destroys all data. Runs as the connecting master role
  (`engram_admin` on RDS), which owns `public`, so `DROP SCHEMA` succeeds.
  After the reset, the DB state equals a fresh-DB state — exactly what CI
  builds and validates green on every push.
  """
  def reset_baseline do
    _ = load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &do_reset_baseline/1)
    end

    :ok
  end

  defp do_reset_baseline(repo) do
    if legacy_integer_pk?(repo) do
      Logger.warning(
        "[reset_baseline] legacy integer-PK schema detected — dropping public " <>
          "and replaying the uuid baseline (PG18/uuidv7 cutover)"
      )

      repo.query!("DROP SCHEMA public CASCADE", [])
      repo.query!("CREATE SCHEMA public", [])
      # Restore the schema grants a fresh cluster would have, so the subsequent
      # prepare_database + baseline GRANTs resolve as on a first deploy.
      repo.query!("GRANT ALL ON SCHEMA public TO CURRENT_USER", [])
      repo.query!("GRANT ALL ON SCHEMA public TO public", [])

      do_prepare_database(repo)
      _ = Ecto.Migrator.run(repo, :up, all: true)

      Logger.warning("[reset_baseline] schema rebuilt from structure.sql (uuid PKs)")
    else
      Logger.info(
        "[reset_baseline] schema is not in the legacy integer-PK state — no-op " <>
          "(safe to leave ENGRAM_DB_RESET_BASELINE set)"
      )
    end

    :ok
  end

  @doc """
  True when `table`'s `id` column is a legacy integer type — i.e. the broken
  pre-cutover state `reset_baseline/0` heals. False for a uuid `id` (healthy)
  or an absent table (fresh DB, baseline will create it). Public for testing.
  """
  def legacy_integer_pk?(repo, table \\ "terms_versions") do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'id'
        """,
        [table]
      )

    case rows do
      [["uuid"]] -> false
      [[_integer_type]] -> true
      [] -> false
    end
  end

  @doc """
  Fail-loud schema-baseline guard. Invoked from `entrypoint.sh` AFTER
  `migrate/0` and BEFORE the app server boots.

  If a database silently kept its legacy integer-PK shape — an in-place engine
  upgrade that preserved data and skipped the wreck-and-recreate baseline replay
  (the 2026-06-11 PG18/uuidv7 incident) — this raises so the deploy fails at the
  migrate step with a one-line diagnosis, instead of the app crash-looping on a
  cryptic `cannot load 1 as type Ecto.UUID` error during `Legal.Seeder`.

  No-op (`:ok`) on a healthy uuid schema (including right after a successful
  `reset_baseline/0`, which heals the state first) or an absent sentinel table.
  """
  def verify_schema_baseline do
    _ = load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &verify_schema_baseline!/1)
    end

    :ok
  end

  @doc """
  Raises when `table`'s `id` is a legacy integer PK (the drift `reset_baseline/0`
  heals), otherwise returns `:ok`. `table` defaults to the `terms_versions`
  sentinel. Public for testing.
  """
  def verify_schema_baseline!(repo, table \\ "terms_versions") do
    if legacy_integer_pk?(repo, table) do
      raise """
      Schema baseline check FAILED: `#{table}.id` is a legacy integer column, but \
      the code expects a uuid PK (PG18/uuidv7 baseline). This database predates the \
      uuidv7 cutover and was never wiped/recreated — an in-place engine upgrade \
      preserves data and silently skips the baseline replay (the 2026-06-11 incident).

      Remedy: deploy once with ENGRAM_DB_RESET_BASELINE=true (DESTROYS ALL DATA, \
      replays the uuid baseline), or write an ALTER ... TYPE uuid data migration if \
      the data must be kept.

      See docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md\
      """
    end

    :ok
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
