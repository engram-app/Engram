defmodule Engram.Release.PreflightAppRoleTest do
  @moduledoc """
  `Preflight.run/0` runs over `bin/engram rpc` on `Engram.Repo`, which connects
  as `engram_app` in a two-login deployment. `engram_app` holds only SELECT on
  `schema_migrations` and no CREATE on `public`, while
  `Ecto.Migrator.migrated_versions/1` runs `CREATE TABLE IF NOT EXISTS` and a
  `SHARE UPDATE EXCLUSIVE` lock. So the version read must be a plain SELECT.
  """
  use Engram.DataCase, async: false

  alias Engram.Release.Preflight

  defp as_app_role(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
      result = fun.()
      Repo.query!("RESET SESSION AUTHORIZATION")
      result
    end)
  end

  test "applied_versions/1 reads schema_migrations as engram_app" do
    assert {:ok, versions} = as_app_role(fn -> Preflight.applied_versions(Repo) end)
    assert 20_261_006_120_000 in versions
  end

  # CONTROL: proves the role drop engaged and the hazard is real. If this ever
  # stops raising, the test above no longer proves anything about privileges.
  test "Ecto.Migrator.migrated_versions/1 is refused for engram_app" do
    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      as_app_role(fn -> Ecto.Migrator.migrated_versions(Repo) end)
    end
  end
end
