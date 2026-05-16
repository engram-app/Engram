defmodule EngramWeb.OnboardingControllerTest do
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

    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/onboarding/status" do
    test "returns next_step=agreement for a new user", %{conn: conn} do
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == true
      assert body["terms_ok"] == false
      assert body["subscription_ok"] == false
      assert body["next_step"] == "agreement"
      assert body["current_tos_version"] == "2026-05-15"
    end

    test "returns next_step=done for fully onboarded user", %{conn: conn, user: user} do
      {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["next_step"] == "done"
    end

    test "returns enabled=false in self-host mode", %{conn: conn} do
      Application.put_env(:engram, :billing_enabled, false)
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == false
      assert body["next_step"] == "done"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    test "201 records acceptance with ip + user_agent", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (test)")
        |> post("/api/onboarding/accept-terms", %{"version" => "2026-05-15"})

      body = json_response(conn, 201)
      assert body["version"] == "2026-05-15"
      assert body["accepted_at"] != nil

      # Verify the row was actually inserted
      {:ok, [agreement]} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Engram.Onboarding.Agreement)
        end)

      assert agreement.user_id == user.id
      assert agreement.version == "2026-05-15"
      assert agreement.user_agent == "Mozilla/5.0 (test)"
    end

    test "422 when version does not match current_tos_version", %{conn: conn} do
      conn = post(conn, "/api/onboarding/accept-terms", %{"version" => "2099-01-01"})
      body = json_response(conn, 422)
      assert body["error"] == "version_mismatch"
    end
  end
end
