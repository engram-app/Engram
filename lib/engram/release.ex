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

  ## How this code reaches an environment

  Both paths end at `terraform apply` in engram-app/engram-infra, which
  is the SOLE image-mover — nothing deploys by pushing to a container
  directly. The two chains differ in what they key on and whether a
  human is in the loop:

    * **staging-fastraid** — a merge to `main` that touches a deployable
      path (`lib`, `priv`, `config`, `frontend`, `Dockerfile`,
      `entrypoint.sh`, `.dockerignore`, `rel`, `mix.exs`, `mix.lock`)
      publishes `ghcr.io/engram-app/engram:<sha7>` and opens a
      `chore(staging-fastraid)` PR bumping `engram_saas_image_tag`.
      That PR auto-merges, and the apply recreates the container. A
      merge touching only CI or docs deliberately does NOT move staging
      — there are no new bytes to ship.

      This is keyed on the commit SHA, not the `mix.exs` version:
      release-please owns that version and keeps it sticky between
      cuts, so a version-keyed bump wrote the same string on every
      non-release merge, Terraform saw no diff, and staging could only
      ever move on a release.

    * **prod** — a `release-v*` tag runs `deploy-prod.yml`, which pushes
      `sha-<7>` to ECR and opens a prod bump PR. That PR is
      deliberately NOT auto-merged: it is the staging-first promotion
      gate, so prod only advances behind a human click after staging
      has been rolling on the same code.

  A green `deploy-prod` run therefore means "a PR was opened", not
  "prod moved" — check the infra PR, not this workflow's status.
  """

  alias Engram.Logger.Metadata

  require Logger

  @app :engram

  # NOINHERIT + LOGIN matches the historical baseline shape (preserved
  # for envs that rely on `engram_app` connecting directly).
  #
  # No PASSWORD here: creation is idempotent behind IF NOT EXISTS, so a
  # password set at creation time could never be rotated. It is applied
  # separately by `set_engram_app_password/1`, which runs on every boot from
  # ENGRAM_APP_DB_PASSWORD and no-ops when that is unset.
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

  # The credential behind MAINTENANCE_DATABASE_URL on SaaS: the pool for work
  # that legitimately spans tenants (see `Engram.Repo.Maintenance`).
  #
  # Deliberately NO BYPASSRLS. RDS cannot grant it: the master is CREATEROLE,
  # not superuser, and PG16+ only lets a CREATEROLE role hand out an attribute
  # it holds itself. Cross-tenant reach comes instead from one permissive
  # `maintenance_all` policy per tenant table, scoped `TO engram_maintenance`
  # (migration 20260925140000). That also keeps the reach visible in the schema
  # and limited to the tables that carry the policy.
  #
  # Same shape as engram_app otherwise: NOINHERIT LOGIN, no memberships, no
  # CREATEROLE/CREATEDB, DML only. No PASSWORD at creation for the same
  # rotation reason; `set_engram_maintenance_password/1` applies it per boot.
  #
  # It must exist BEFORE `migrate/0`: `CREATE POLICY ... TO engram_maintenance`
  # fails on an unknown role. Every path that migrates (entrypoint.sh, the
  # `ecto.setup` and `test` aliases, CI) runs this first, as for engram_app.
  @create_engram_maintenance_role_sql """
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_maintenance') THEN
      CREATE ROLE engram_maintenance NOINHERIT LOGIN;
    END IF;
  END
  $$;
  """

  # Unlike engram_app, existing tables are granted HERE rather than by the
  # baseline dump: this role postdates the baseline, and on an established
  # database (prod, staging) no migration will recreate those tables. On a
  # fresh database this matches nothing and the DEFAULT PRIVILEGES below cover
  # every table the migrator then creates. Both are idempotent.
  @engram_maintenance_grants_sql [
    "GRANT USAGE ON SCHEMA public TO engram_maintenance;",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO engram_maintenance;",
    "GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA public TO engram_maintenance;",
    """
    ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO engram_maintenance;
    """,
    """
    ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
      GRANT SELECT, USAGE ON SEQUENCES TO engram_maintenance;
    """
  ]

  @doc """
  Idempotent cluster bootstrap. Run BEFORE `migrate/0`.

  Creates the `engram_app` role and configures DEFAULT PRIVILEGES so
  the connecting role's future objects auto-grant CRUD on tables +
  SELECT/USAGE on sequences to `engram_app`. Existing objects are
  granted explicitly by the baseline migration's structure.sql dump.

  Does the same for `engram_maintenance`, the cross-tenant maintenance
  credential, and additionally grants it on existing objects (it
  postdates the baseline).

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
          "and replaying the uuid baseline (PG18/uuidv7 cutover)",
        Metadata.with_category(:warning, :boot, [])
      )

      repo.query!("DROP SCHEMA public CASCADE", [])
      repo.query!("CREATE SCHEMA public", [])
      # Restore the schema grants a fresh cluster would have, so the subsequent
      # prepare_database + baseline GRANTs resolve as on a first deploy.
      repo.query!("GRANT ALL ON SCHEMA public TO CURRENT_USER", [])
      repo.query!("GRANT ALL ON SCHEMA public TO public", [])

      do_prepare_database(repo)
      _ = Ecto.Migrator.run(repo, :up, all: true)

      Logger.warning(
        "[reset_baseline] schema rebuilt from structure.sql (uuid PKs)",
        Metadata.with_category(:warning, :boot, [])
      )
    else
      Logger.info(
        "[reset_baseline] schema is not in the legacy integer-PK state — no-op " <>
          "(safe to leave ENGRAM_DB_RESET_BASELINE set)",
        Metadata.with_category(:info, :boot, [])
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
    set_engram_app_password(repo)
    repo.query!(@grant_schema_usage_sql, [])
    repo.query!(@default_priv_tables_sql, [])
    repo.query!(@default_priv_sequences_sql, [])

    repo.query!(@create_engram_maintenance_role_sql, [])
    set_engram_maintenance_password(repo)
    Enum.each(@engram_maintenance_grants_sql, &repo.query!(&1, []))
    :ok
  end

  # `ALTER ROLE engram_app PASSWORD`, from ENGRAM_APP_DB_PASSWORD.
  # Public only so it can be tested against a real connection; not an API.
  #
  # Unset is the normal case and a no-op: self-host, dev and CI all connect as
  # the owner and never need `engram_app` to log in. Only a deployment doing
  # privilege separation sets it.
  #
  # ## Why this lives in the boot path
  #
  # It has to run somewhere with CREATEROLE against the database, and on AWS
  # that is a shorter list than it looks. RDS is `publicly_accessible = false`
  # in private subnets, the VPC has no NAT, and the CI runners are self-hosted
  # in a homelab — so no Terraform provider has a TCP path to port 5432, and
  # every DB role here has historically been created by hand through the SSM
  # bastion (`engram_metrics_ro`, `engram_audit_ro`). The app container is
  # already inside the VPC, already holds a CREATEROLE credential, and already
  # runs `CREATE ROLE engram_app` three lines up. Putting the password beside
  # the role creation deletes a manual step rather than adding a mechanism.
  #
  # The old comment on @create_engram_app_role_sql said "PASSWORD intentionally
  # absent — privilege separation is a separate concern wired via DATABASE_URL
  # itself". True while nothing set a password; it left the password as the one
  # piece of the cutover with no owner, and it stalled #1649.
  #
  # ## Why it sends a SCRAM VERIFIER rather than the password
  #
  # `ALTER ROLE ... PASSWORD` is utility DDL and accepts no bind parameter, so
  # whatever it is given becomes part of the statement TEXT. That matters here
  # because `pg_stat_statements` does not normalise utility statements — it
  # stores them verbatim — and `engram_metrics_ro` holds `pg_monitor`, which
  # can read it. Sending the plaintext would hand the app's database password
  # to the metrics exporter role.
  #
  # Postgres accepts a pre-computed RFC 5802 verifier and stores it unchanged,
  # which is precisely what that format is for. So the plaintext never leaves
  # this process; what lands in the statement log is the same hash already
  # sitting in `pg_authid`.
  #
  # (A `DO $$ ... EXECUTE format(..., $1) $$` block does NOT solve this: `$1`
  # inside a dollar-quoted body is literal text, not a placeholder, and
  # Postgrex rejects the call with "parameters must be of length 0".)
  #
  # ## Why ALTER every boot rather than only on create
  #
  # Rotation. Setting it only inside the `IF NOT EXISTS` branch would mean a
  # rotated secret never reaches Postgres and the app locks itself out at the
  # next task replacement, with the symptom arriving hours later. A fresh salt
  # each boot makes the verifier differ every time, which is harmless — the
  # password it encodes is what has to stay stable.
  @doc false
  def set_engram_app_password(repo),
    do: set_role_password(repo, "engram_app", "ENGRAM_APP_DB_PASSWORD")

  # `ALTER ROLE engram_maintenance PASSWORD`, from ENGRAM_MAINTENANCE_DB_PASSWORD.
  # Everything above applies unchanged; only the role and the variable differ.
  # Unset everywhere except a SaaS deployment that sets MAINTENANCE_DATABASE_URL.
  @doc false
  def set_engram_maintenance_password(repo),
    do: set_role_password(repo, "engram_maintenance", "ENGRAM_MAINTENANCE_DB_PASSWORD")

  # `role` and `env_var` are compile-time literals from the two wrappers above,
  # never input; the password itself only ever reaches Postgres as a verifier.
  defp set_role_password(repo, role, env_var) do
    case System.get_env(env_var) do
      nil ->
        :ok

      "" ->
        # Same meaning as unset. An empty ECS/SOPS value must never become
        # `PASSWORD ''`, which is a role anyone can authenticate as while
        # looking like a successful rotation.
        :ok

      password ->
        repo.query!("ALTER ROLE #{role} PASSWORD '#{scram_verifier(password)}'", [])

        Logger.info(
          "#{role} password applied from #{env_var}",
          Metadata.with_category(:info, :boot, [])
        )

        :ok
    end
  end

  # RFC 5802 / RFC 7677 SCRAM-SHA-256 verifier, in the on-disk shape Postgres
  # writes to `pg_authid.rolpassword`:
  #
  #     SCRAM-SHA-256$<iterations>:<b64 salt>$<b64 StoredKey>:<b64 ServerKey>
  #
  # 4096 iterations and a 16-byte salt match Postgres' own defaults
  # (`scram_sha_256_build_secret`), so a role configured here is
  # indistinguishable from one configured with a plain `PASSWORD 'x'`.
  #
  # The verifier is interpolated rather than bound, which is safe here and
  # nowhere else: every byte of it is base64 or punctuation from THIS function,
  # never from the password, so there is no input that can close the quote.
  @scram_iterations 4096
  @scram_salt_bytes 16

  # Public only so a test can prove a real login succeeds against it; the
  # `ALTER ROLE` wrapper above is trivially correct, this is the part that can
  # be subtly and silently wrong.
  @doc false
  def scram_verifier(password, salt \\ :crypto.strong_rand_bytes(@scram_salt_bytes)) do
    salted =
      :crypto.pbkdf2_hmac(:sha256, password, salt, @scram_iterations, 32)

    stored_key = :crypto.hash(:sha256, :crypto.mac(:hmac, :sha256, salted, "Client Key"))
    server_key = :crypto.mac(:hmac, :sha256, salted, "Server Key")

    "SCRAM-SHA-256$#{@scram_iterations}:#{Base.encode64(salt)}$" <>
      "#{Base.encode64(stored_key)}:#{Base.encode64(server_key)}"
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
