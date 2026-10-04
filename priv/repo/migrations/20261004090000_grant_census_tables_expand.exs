defmodule Engram.Repo.Migrations.GrantCensusTablesExpand do
  use Ecto.Migration

  # phase/expand — explicit runtime grants for the self-host census tables
  # (#1828). `Engram.Release.prepare_database/0` sets DEFAULT PRIVILEGES for the
  # migrating role, which already covers these tables wherever it ran; every
  # other create-table migration additionally grants explicitly, and these two
  # shipped without. Redundant where the defaults apply, and the safety net
  # where they do not (a migrator role that differs from the one that ran
  # prepare_database). Idempotent.
  #
  # `down` is deliberately a no-op, not a REVOKE: where the default privileges
  # already granted access, a REVOKE would strip access this migration never
  # added and break the census writers (heartbeat, collector, pruner) on a
  # plain rollback of this one version.

  @doc false
  def grant_sql do
    "GRANT SELECT, INSERT, UPDATE, DELETE ON instance_telemetry, install_pings TO engram_app"
  end

  def up, do: execute(grant_sql())

  def down, do: :ok
end
