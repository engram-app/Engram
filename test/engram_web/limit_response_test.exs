defmodule EngramWeb.LimitResponseTest do
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.LimitResponse

  describe "halt/5" do
    test "returns 402 with full shape and tier from current_user" do
      user = insert(:user, free_tier_accepted_at: DateTime.utc_now())
      conn = build_conn() |> assign(:current_user, user)
      conn = LimitResponse.halt(conn, "notes_cap_exceeded", :notes_cap, 10_000, 10_000)
      assert conn.halted
      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)

      assert body == %{
               "error" => "limit_exceeded",
               "reason" => "notes_cap_exceeded",
               "tier" => "free",
               "limit_key" => "notes_cap",
               "limit" => 10_000,
               "current" => 10_000,
               "upgrade_url" => "https://app.engram.page/settings/billing"
             }
    end

    test "halt/5 with nil limit_key/limit/current emits nulls in body" do
      user = insert(:user, free_tier_accepted_at: DateTime.utc_now())
      conn = build_conn() |> assign(:current_user, user)
      conn = LimitResponse.halt(conn, "account_suspended", nil, nil, nil)
      body = Jason.decode!(conn.resp_body)
      assert body["reason"] == "account_suspended"
      assert body["limit_key"] == nil
      assert body["limit"] == nil
      assert body["current"] == nil
    end

    test "tier nil when current_user is nil" do
      conn = build_conn() |> assign(:current_user, nil)
      conn = LimitResponse.halt(conn, "no_tier", nil, nil, nil)
      assert Jason.decode!(conn.resp_body)["tier"] == nil
    end

    test "upgrade_url is nil when config sets it nil" do
      Application.put_env(:engram, :upgrade_url, nil)

      on_exit(fn ->
        Application.put_env(:engram, :upgrade_url, "https://app.engram.page/settings/billing")
      end)

      user = insert(:user, free_tier_accepted_at: DateTime.utc_now())
      conn = build_conn() |> assign(:current_user, user)
      conn = LimitResponse.halt(conn, "notes_cap_exceeded", :notes_cap, 10_000, 10_000)
      assert Jason.decode!(conn.resp_body)["upgrade_url"] == nil
    end
  end
end
