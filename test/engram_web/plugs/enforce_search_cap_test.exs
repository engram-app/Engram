defmodule EngramWeb.Plugs.EnforceSearchCapTest do
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.EnforceSearchCap

  # The DB sandbox resets `usage_buckets` per test. Note DailyCap's ETS
  # empty-verdict cache is global and NOT sandboxed — isolation there comes
  # from each `insert(:user)` minting a unique UUID, so cache keys never collide.

  describe "EnforceSearchCap" do
    setup %{conn: conn} do
      free_user = insert(:user)
      paid_user = insert(:user)

      # Paid tier defaults to `nil` (no enforcement) on both caps. Override
      # explicitly anyway so test failure here surfaces a real regression
      # in the default, not just an unrelated catalog change.
      for key <- ~w(external_ai_searches_per_day inapp_searches_per_day) do
        insert(:user_limit_override, user: paid_user, key: key, value: %{"v" => nil})
      end

      {:ok, conn: conn, free: free_user, paid: paid_user}
    end

    test "ignores requests that aren't POST /api/search", %{conn: conn, free: user} do
      conn =
        conn
        |> Map.put(:method, "GET")
        |> Map.put(:request_path, "/api/notes/foo.md")
        |> assign(:current_user, user)
        |> assign(:current_auth_method, :internal_jwt)
        |> EnforceSearchCap.call([])

      refute conn.halted
    end

    test "in-app (Clerk JWT — no markers) hits the inapp cap", %{conn: conn, free: user} do
      # Pin to 1 to make the boundary tight.
      insert(:user_limit_override,
        user: user,
        key: "inapp_searches_per_day",
        value: %{"v" => 1}
      )

      hit = fn -> EnforceSearchCap.call(search_conn(conn, user, :inapp), []) end

      refute hit.().halted
      halted = hit.()
      assert halted.halted
      body = Phoenix.ConnTest.json_response(halted, 402)
      assert body["reason"] == "inapp_searches_per_day_exceeded"
      assert body["limit_key"] == "inapp_searches_per_day"
      assert body["limit"] == 1
      assert body["tier"] == "free"
    end

    test "external (PAT or internal-JWT) hits the external cap", %{conn: conn, free: user} do
      insert(:user_limit_override,
        user: user,
        key: "external_ai_searches_per_day",
        value: %{"v" => 1}
      )

      hit = fn -> EnforceSearchCap.call(search_conn(conn, user, :external_jwt), []) end

      refute hit.().halted
      halted = hit.()
      assert halted.halted
      body = Phoenix.ConnTest.json_response(halted, 402)
      assert body["reason"] == "external_ai_searches_per_day_exceeded"
      assert body["limit_key"] == "external_ai_searches_per_day"
    end

    test "external + in-app caps are independent (separate buckets)", %{conn: conn, free: user} do
      # Pin both caps to 1. Exhaust external; in-app should still pass.
      for {k, v} <- [
            {"external_ai_searches_per_day", 1},
            {"inapp_searches_per_day", 1}
          ] do
        insert(:user_limit_override, user: user, key: k, value: %{"v" => v})
      end

      _ = EnforceSearchCap.call(search_conn(conn, user, :external_jwt), [])
      blocked = EnforceSearchCap.call(search_conn(conn, user, :external_jwt), [])
      assert blocked.halted

      # In-app bucket is untouched — the FIRST in-app call should pass.
      inapp_ok = EnforceSearchCap.call(search_conn(conn, user, :inapp), [])
      refute inapp_ok.halted
    end

    test "PAT auth also routes to the external bucket", %{conn: conn, free: user} do
      insert(:user_limit_override,
        user: user,
        key: "external_ai_searches_per_day",
        value: %{"v" => 1}
      )

      api_key = %Engram.Accounts.ApiKey{id: 1, name: "test"}

      hit = fn -> EnforceSearchCap.call(search_conn(conn, user, {:pat, api_key}), []) end

      refute hit.().halted
      assert hit.().halted
    end

    test "paid user passes regardless of bucket", %{conn: conn, paid: user} do
      conn = EnforceSearchCap.call(search_conn(conn, user, :external_jwt), [])
      refute conn.halted
    end
  end

  defp search_conn(conn, user, auth) do
    conn
    |> Map.put(:method, "POST")
    |> Map.put(:request_path, "/api/search")
    |> assign(:current_user, user)
    |> apply_auth(auth)
  end

  defp apply_auth(conn, :inapp), do: conn
  defp apply_auth(conn, :external_jwt), do: assign(conn, :current_auth_method, :internal_jwt)
  defp apply_auth(conn, {:pat, key}), do: assign(conn, :current_api_key, key)
end
