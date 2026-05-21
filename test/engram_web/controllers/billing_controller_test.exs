defmodule EngramWeb.BillingControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/billing/status" do
    test "returns inactive status for new user with no subscription", %{conn: conn} do
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "free"
      assert body["active"] == false
      assert body["trial_days_remaining"] == 0
      assert body["subscription"] == nil
    end

    test "returns subscription status for subscribed user", %{conn: conn, user: user} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "starter"
      assert body["active"] == true
      assert body["subscription"]["status"] == "active"
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/status")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/billing/config" do
    test "returns Paddle.js overlay config for the authenticated user", %{conn: conn, user: user} do
      conn = get(conn, "/api/billing/config")
      body = json_response(conn, 200)

      assert body["client_token"] == "live_token_test_fake"
      assert body["environment"] == "sandbox"
      assert body["price_ids"]["starter"] == "pri_starter_test"
      assert body["price_ids"]["pro"] == "pri_pro_test"
      assert body["customer_email"] == user.email
      assert body["custom_data"]["user_id"] == user.id
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/config")
      assert json_response(conn, 401)
    end
  end
end
