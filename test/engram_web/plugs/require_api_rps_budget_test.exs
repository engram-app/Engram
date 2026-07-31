defmodule EngramWeb.Plugs.RequireApiRpsBudgetTest do
  # async: false — the rate-limiter bucket store is global; tests reset it in setup.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.RequireApiRpsBudget

  setup do
    user = insert(:user)
    api_key = %Engram.Accounts.ApiKey{id: 1, user_id: user.id, name: "test"}
    EngramWeb.RateLimiter.reset_buckets!()

    # Hammer derives its bucket from wall-clock (`div(now_ms, scale_ms)`), so
    # against the production 1 s window a burst of N+1 calls is racing a real
    # second boundary: under runner load the warm-up calls straddle it, the
    # bucket resets, and the call that must be denied is back under cap
    # (#1080 / #936). Widening the window makes every call in a burst land in
    # ONE bucket by construction — the cap behaviour under test is unchanged,
    # only the timing assumption is removed. `async: false` + reset_buckets!
    # above means the wider window cannot leak between tests.
    Application.put_env(:engram, :api_rps_period_ms, 60_000)
    on_exit(fn -> Application.delete_env(:engram, :api_rps_period_ms) end)

    %{user: user, api_key: api_key}
  end

  # The seam must not drift prod. If someone sets :api_rps_period_ms in
  # runtime.exs, "RPS" silently stops meaning per-second.
  test "the window defaults to one second when unconfigured" do
    Application.delete_env(:engram, :api_rps_period_ms)
    user = insert(:user)
    api_key = %Engram.Accounts.ApiKey{id: 1, user_id: user.id, name: "test"}

    conn =
      Phoenix.ConnTest.build_conn()
      |> assign(:current_user, user)
      |> assign(:current_api_key, api_key)
      |> RequireApiRpsBudget.call([])

    # Free tier caps at 0, so this denies immediately and the body carries the
    # window the plug actually used.
    assert Phoenix.ConnTest.json_response(conn, 429)["period_ms"] == 1_000
  end

  describe "JWT-authed (no current_api_key)" do
    test "passes through — web app is not subject to API RPS cap", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_user, user)
        |> RequireApiRpsBudget.call([])

      refute conn.halted
    end
  end

  describe "API-key-authed — Free (api_rps_cap=0)" do
    test "halts 429 immediately on every request", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiRpsBudget.call([])

      assert conn.halted
      assert conn.status == 429
      body = Phoenix.ConnTest.json_response(conn, 429)
      assert body["error"] == "api_rps_exceeded"
      assert body["limit"] == 0
    end
  end

  describe "API-key-authed — Starter / Pro (positive cap)" do
    setup %{user: user} do
      insert(:user_limit_override,
        user: user,
        key: "api_rps_cap",
        value: %{"v" => 3}
      )

      :ok
    end

    test "allows requests under the per-second cap", %{conn: conn, user: user, api_key: api_key} do
      for _ <- 1..3 do
        c =
          conn
          |> assign(:current_user, user)
          |> assign(:current_api_key, api_key)
          |> RequireApiRpsBudget.call([])

        refute c.halted
      end
    end

    test "halts 429 once the cap is exceeded within one window",
         %{conn: conn, user: user, api_key: api_key} do
      for _ <- 1..3 do
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiRpsBudget.call([])
      end

      denied =
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiRpsBudget.call([])

      assert denied.halted
      assert denied.status == 429
      body = Phoenix.ConnTest.json_response(denied, 429)
      assert body["error"] == "api_rps_exceeded"
      assert body["limit"] == 3
    end
  end

  describe "self-host bypass" do
    test "passes through when limits_enforced=false (Paddle key unset)",
         %{conn: conn, user: user, api_key: api_key} do
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, true) end)

      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiRpsBudget.call([])

      refute conn.halted
    end
  end

  describe "per-user isolation" do
    test "user A's budget exhaustion does not affect user B",
         %{conn: conn, user: user, api_key: api_key} do
      # Grant a small cap to user A
      insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 2})

      for _ <- 1..3 do
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiRpsBudget.call([])
      end

      # User B with a separate cap
      user_b = insert(:user)
      insert(:user_limit_override, user: user_b, key: "api_rps_cap", value: %{"v" => 2})
      api_key_b = %Engram.Accounts.ApiKey{id: 2, user_id: user_b.id, name: "b"}
      EngramWeb.RateLimiter.reset_buckets!()

      conn_b =
        build_conn()
        |> assign(:current_user, user_b)
        |> assign(:current_api_key, api_key_b)
        |> RequireApiRpsBudget.call([])

      refute conn_b.halted
    end
  end
end
