defmodule EngramWeb.AccountLifecycleWiringTest do
  @moduledoc """
  Integration smoke tests proving EngramWeb.Plugs.AccountLifecycle is wired on
  the user-scoped (management-plane) pipeline — the gap the audit flagged: a
  suspended/soft-deleted user could otherwise mint API keys, CRUD vaults, and
  change billing until their JWT expired.

  The vault-scoped pipeline keeps its existing AccountDeleted (410) +
  RequireActiveSubscription (402 account_suspended) behavior — covered by
  RouterPipelineTest and OnboardingGateIntegrationTest — so it is not re-tested
  here.
  """
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp suspend(user) do
    user
    |> Ecto.Changeset.change(%{suspended_at: DateTime.utc_now()})
    |> Engram.Repo.update!(skip_tenant_check: true)
  end

  defp soft_delete(user) do
    user
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Engram.Repo.update!(skip_tenant_check: true)
  end

  test "suspended user gets 403 on a user-scoped management endpoint", %{conn: conn, user: user} do
    suspend(user)

    conn = get(conn, "/api/vaults")

    assert conn.status == 403
    assert %{"error" => "account_suspended"} = json_response(conn, 403)
  end

  test "soft-deleted user gets 410 on a user-scoped management endpoint", %{
    conn: conn,
    user: user
  } do
    soft_delete(user)

    conn = get(conn, "/api/vaults")

    assert conn.status == 410
    assert %{"error" => "account_deleted"} = json_response(conn, 410)
  end

  test "suspended user can still reach billing (self-reactivate exemption)", %{
    conn: conn,
    user: user
  } do
    suspend(user)

    # AccountLifecycle must NOT halt billing — exempt so a suspended user can
    # pay to reactivate. (The controller then handles the request normally.)
    assert get(conn, "/api/billing/status").status != 403
  end

  test "active user proceeds past the gate on the management plane", %{conn: conn} do
    assert get(conn, "/api/vaults").status not in [403, 410]
  end
end
