defmodule Engram.Telemetry.CensusGrantsTest do
  @moduledoc """
  The census tables must be usable by `engram_app`, the prod runtime role. The
  whole suite connects as a superuser, which ignores GRANTs, so a green run of
  the code under test proves nothing about a missing grant. Each test drops to
  `engram_app` the same way the RLS tests do (`Engram.RlsCase`).

  The test DB also has DEFAULT PRIVILEGES (from `Engram.Release.prepare_database/0`),
  so the CRUD tests alone pass without the grant migration. The last test is the
  one that pins the migration: it revokes, proves access is denied, then runs the
  migration's own grant SQL and proves access is back.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Repo

  @migration_mod Engram.Repo.Migrations.GrantCensusTablesExpand
  @migration_file "priv/repo/migrations/20261004090000_grant_census_tables_expand.exs"

  defp uuid_bin, do: Ecto.UUID.dump!(Ecto.UUID.generate())

  # Full CRUD on install_pings as the current (dropped) role; raises on a missing grant.
  defp crud_install_pings do
    id = uuid_bin()

    Repo.query!(
      "INSERT INTO install_pings (id, version, os, arch, runtime, inserted_at, updated_at) " <>
        "VALUES ($1, 'v', 'linux', 'amd64', 'docker', now(), now())",
      [id]
    )

    %{num_rows: 1} = Repo.query!("SELECT 1 FROM install_pings WHERE id = $1", [id])
    %{num_rows: 1} = Repo.query!("UPDATE install_pings SET version = 'w' WHERE id = $1", [id])
    %{num_rows: 1} = Repo.query!("DELETE FROM install_pings WHERE id = $1", [id])
    :ok
  end

  defp crud_instance_telemetry do
    id = uuid_bin()

    Repo.query!(
      "INSERT INTO instance_telemetry (id, install_id, inserted_at, updated_at) " <>
        "VALUES ($1, $1, now(), now())",
      [id]
    )

    %{num_rows: 1} = Repo.query!("SELECT 1 FROM instance_telemetry WHERE id = $1", [id])

    %{num_rows: 1} =
      Repo.query!("UPDATE instance_telemetry SET telemetry_enabled = false WHERE id = $1", [id])

    %{num_rows: 1} = Repo.query!("DELETE FROM instance_telemetry WHERE id = $1", [id])
    :ok
  end

  # The migration module is already loaded when the migrator compiled it for the
  # test run; otherwise load the file. Deleting the migration fails this test.
  defp migration do
    unless Code.ensure_loaded?(@migration_mod),
      do: Code.require_file(Path.expand(@migration_file))

    @migration_mod
  end

  test "the role drop engaged: the helper really runs as engram_app" do
    assert {:returned, [["engram_app"]]} =
             as_prod_role(fn -> Repo.query!("SELECT session_user").rows end)
  end

  test "engram_app can insert, read, update and delete install_pings" do
    assert {:returned, :ok} = as_prod_role(&crud_install_pings/0)
  end

  test "engram_app can insert, read, update and delete instance_telemetry" do
    assert {:returned, :ok} = as_prod_role(&crud_instance_telemetry/0)
  end

  test "the migration's own grant SQL is what gives engram_app access" do
    # DDL is transactional in Postgres: the REVOKE is undone when the sandbox rolls back.
    Repo.query!("REVOKE ALL ON instance_telemetry, install_pings FROM engram_app")

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_prod_role(&crud_install_pings/0)

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_prod_role(&crud_instance_telemetry/0)

    Repo.query!(migration().grant_sql())

    assert {:returned, :ok} = as_prod_role(&crud_install_pings/0)
    assert {:returned, :ok} = as_prod_role(&crud_instance_telemetry/0)
  end
end
