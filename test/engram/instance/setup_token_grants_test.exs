defmodule Engram.Instance.SetupTokenGrantsTest do
  @moduledoc """
  `instance_setup_token` must be usable by `engram_app`, the prod runtime role.
  The suite connects as a superuser, which ignores GRANTs, so each test drops to
  `engram_app` (`Engram.RlsCase`). Without access, `valid?/1` would raise (500,
  not 403) and `burn/0` would fail inside the admin-claim transaction.

  The test DB has DEFAULT PRIVILEGES, so the plain CRUD test passes even without
  the grant migration. The revoke/re-grant test is the one that pins the
  migration (same shape as `Engram.Telemetry.CensusGrantsTest`).
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Instance.SetupToken
  alias Engram.Repo

  @migration_mod Engram.Repo.Migrations.GrantInstanceSetupTokenExpand
  @migration_file "priv/repo/migrations/20261110120000_grant_instance_setup_token_expand.exs"

  defp migration do
    unless Code.ensure_loaded?(@migration_mod),
      do: Code.require_file(Path.expand(@migration_file))

    @migration_mod
  end

  # Mint, read (valid?), and burn: the three operations the app performs, as the dropped role.
  defp mint_read_burn do
    {:ok, _} = SetupToken.mint("grant-test-token-abcdefgh")
    true = SetupToken.valid?("grant-test-token-abcdefgh")
    :ok = SetupToken.burn()
    false = SetupToken.valid?("grant-test-token-abcdefgh")
    :ok
  end

  test "the role drop engaged: the helper really runs as engram_app" do
    assert {:returned, [["engram_app"]]} =
             as_prod_role(fn -> Repo.query!("SELECT session_user").rows end)
  end

  test "control: the dropped role sees no token before one is minted" do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.query!("SELECT 1 FROM instance_setup_token").num_rows
             end)
  end

  test "engram_app can mint, read and burn the token" do
    assert {:returned, :ok} = as_prod_role(&mint_read_burn/0)
  end

  test "the migration's own grant SQL is what gives engram_app access" do
    # DDL is transactional in Postgres: the REVOKE is undone when the sandbox rolls back.
    Repo.query!("REVOKE ALL ON instance_setup_token FROM engram_app")

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_prod_role(&mint_read_burn/0)

    Repo.query!(migration().grant_sql())

    assert {:returned, :ok} = as_prod_role(&mint_read_burn/0)
  end

  test "the grant SQL is a no-op where the table does not exist yet (previous release's schema)" do
    Repo.query!("DROP TABLE instance_setup_token")

    assert %Postgrex.Result{} = Repo.query!(migration().grant_sql())
  end
end
