defmodule EngramWeb.Plugs.RequireApiRpsBudgetTest do
  # async: false — Hammer's bucket store is global; tests delete buckets in setup.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.RequireApiRpsBudget

  setup do
    user = insert(:user)
    api_key = %Engram.Accounts.ApiKey{id: 1, user_id: user.id, name: "test"}
    Hammer.delete_buckets("api_rps:#{user.id}")
    %{user: user, api_key: api_key}
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

    test "halts 429 once cap is exceeded within the same second",
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
      Hammer.delete_buckets("api_rps:#{user_b.id}")

      conn_b =
        build_conn()
        |> assign(:current_user, user_b)
        |> assign(:current_api_key, api_key_b)
        |> RequireApiRpsBudget.call([])

      refute conn_b.halted
    end
  end
end
