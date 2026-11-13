defmodule Engram.Repo.Migrations.GrantInstanceSetupTokenExpand do
  use Ecto.Migration

  # phase/expand — explicit runtime grant for `instance_setup_token` (the
  # self-host first-run setup token). `Engram.Release.prepare_database/0` sets
  # DEFAULT PRIVILEGES for the migrating role, which usually covers new tables;
  # every other create-table migration also grants explicitly, and this one
  # shipped without. Redundant where the defaults apply, and the safety net
  # where they do not. Without access `SetupToken.valid?/1` raises (500, not
  # 403) and `burn/0` fails inside the admin-claim transaction. Idempotent.
  #
  # `down` is a no-op, not a REVOKE, for the reason in
  # 20261004090000_grant_census_tables_expand.exs.
  #
  # Conditional on the table existing: CI's n1-compat gate applies a PR's new
  # migrations over the previous release's schema, which predates the table.
  @doc false
  def grant_sql do
    """
    DO $$
    BEGIN
      IF to_regclass('public.instance_setup_token') IS NOT NULL THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON instance_setup_token TO engram_app;
      END IF;
    END
    $$;
    """
  end

  def up, do: execute(grant_sql())

  def down, do: :ok
end
