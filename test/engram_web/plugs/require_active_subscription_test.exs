defmodule EngramWeb.Plugs.RequireActiveSubscriptionTest do
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.Plugs.RequireActiveSubscription

  describe "call/2" do
    test "passes Free user (no subscription, not suspended)" do
      user = insert(:user, free_tier_accepted_at: DateTime.utc_now(), suspended_at: nil)
      conn = build_conn() |> assign(:current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "passes Pro user (active sub, not suspended)" do
      user =
        insert(:user, suspended_at: nil)
        |> with_subscription(tier: "pro", status: "active")

      conn = build_conn() |> assign(:current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "passes Starter user" do
      user =
        insert(:user, suspended_at: nil)
        |> with_subscription(tier: "starter", status: "active")

      conn = build_conn() |> assign(:current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "passes a user with neither paid sub nor free_tier_accepted_at (defaults to Free)" do
      user = insert(:user, free_tier_accepted_at: nil, suspended_at: nil)
      conn = build_conn() |> assign(:current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "402 + reason account_suspended when suspended_at set" do
      user =
        insert(:user,
          free_tier_accepted_at: DateTime.utc_now(),
          suspended_at: DateTime.utc_now()
        )

      conn = build_conn() |> assign(:current_user, user) |> RequireActiveSubscription.call([])

      assert conn.halted
      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "account_suspended"
      assert body["tier"] == "free"
      assert body["upgrade_url"] =~ "/settings/billing"
    end
  end
end
