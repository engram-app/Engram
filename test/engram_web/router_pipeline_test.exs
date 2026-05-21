defmodule EngramWeb.RouterPipelineTest do
  @moduledoc """
  Vault-scoped pipeline wiring smoke tests.

  Closes #194 — guards against regression where §C plugs (BumpActivity +
  AccountDeleted) were defined but never added to the router pipeline.
  These tests fail if either plug is removed from the pipeline.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.UsageMeters

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  describe "AccountDeleted plug wiring" do
    test "soft-deleted user gets 410 Gone on a vault-scoped endpoint", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
      |> Engram.Repo.update!(skip_tenant_check: true)

      conn = get(conn, "/api/notes/changes")

      assert conn.status == 410
      assert %{"error" => "account_deleted"} = json_response(conn, 410)
    end

    test "non-deleted user proceeds past AccountDeleted", %{conn: conn} do
      conn = get(conn, "/api/notes/changes")
      # Any status other than 410 proves AccountDeleted didn't halt
      refute conn.status == 410
    end
  end

  describe "BumpActivity plug wiring" do
    test "stamps last_active_at on first authenticated vault-scoped request",
         %{conn: conn, user: user} do
      assert is_nil(UsageMeters.last_active_at(user.id))

      _ = get(conn, "/api/notes/changes")

      assert %DateTime{} = UsageMeters.last_active_at(user.id)
    end
  end
end
