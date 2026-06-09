defmodule EngramWeb.Plugs.EnforceExternalQueryCapTest do
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.EnforceExternalQueryCap

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  describe "EnforceExternalQueryCap" do
    setup %{conn: conn} do
      free_user = insert(:user)
      paid_user = insert(:user)

      # Paid user gets unlimited via override (the catalog default for
      # `external_queries_per_day` on starter/pro is nil).
      insert(:user_limit_override,
        user: paid_user,
        key: "external_queries_per_day",
        value: %{"v" => nil}
      )

      {:ok, conn: conn, free: free_user, paid: paid_user}
    end

    test "exempts web-SPA (Clerk JWT — only :current_user set)", %{conn: conn, free: user} do
      # Burn the cap on a different keyspace first to prove this call
      # isn't deferred to a counter call at all.
      conn =
        conn
        |> assign(:current_user, user)
        |> EnforceExternalQueryCap.call([])

      refute conn.halted
    end

    test "counts API-key (PAT) requests", %{conn: conn, free: user} do
      api_key = build_api_key()

      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> EnforceExternalQueryCap.call([])

      refute conn.halted
    end

    test "counts internal-JWT (device-flow / OAuth / MCP) requests", %{conn: conn, free: user} do
      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_auth_method, :internal_jwt)
        |> EnforceExternalQueryCap.call([])

      refute conn.halted
    end

    test "halts 402 with full body when over the daily cap", %{conn: conn, free: user} do
      # Pin the cap to 2 so we don't pummel the limiter.
      insert(:user_limit_override,
        user: user,
        key: "external_queries_per_day",
        value: %{"v" => 2}
      )

      hit = fn ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_auth_method, :internal_jwt)
        |> EnforceExternalQueryCap.call([])
      end

      assert refute_halted(hit.())
      assert refute_halted(hit.())

      halted = hit.()
      assert halted.halted
      assert halted.status == 402
      body = Phoenix.ConnTest.json_response(halted, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "external_queries_per_day_exceeded"
      assert body["limit_key"] == "external_queries_per_day"
      assert body["limit"] == 2
      assert body["tier"] == "free"
    end

    test "passes for paid user with unlimited override", %{conn: conn, paid: user} do
      conn =
        conn
        |> assign(:current_user, user)
        |> assign(:current_auth_method, :internal_jwt)
        |> EnforceExternalQueryCap.call([])

      refute conn.halted
    end
  end

  defp build_api_key, do: %Engram.Accounts.ApiKey{id: 1, name: "test"}

  defp refute_halted(%Plug.Conn{halted: false} = conn), do: conn
end
