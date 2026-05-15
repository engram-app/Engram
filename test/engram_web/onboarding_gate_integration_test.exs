defmodule EngramWeb.OnboardingGateIntegrationTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    prev_version = Application.get_env(:engram, :current_tos_version)
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      Application.put_env(:engram, :current_tos_version, prev_version)
    end)

    user = insert_user()
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  test "GET /api/folders returns 403 onboarding_required for new user", %{conn: conn} do
    conn = get(conn, "/api/folders")
    body = json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert "subscription" in body["missing"]
    assert "terms" in body["missing"]
  end

  test "GET /api/folders returns 200 after onboarding completes", %{conn: conn, user: user} do
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")

    conn = get(conn, "/api/folders")
    assert conn.status == 200
  end

  test "GET /api/folders returns 200 in self-host mode", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    conn = get(conn, "/api/folders")
    assert conn.status == 200
  end
end
