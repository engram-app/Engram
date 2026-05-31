defmodule EngramWeb.Plugs.EnforcePatCreationTest do
  # async: false — matches RequireApiWriteEnabled convention; avoids flaky
  # interactions if Application env is ever toggled in a related test.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.EnforcePatCreation

  describe "EnforcePatCreation" do
    test "halts with 402 when api_write_enabled is false (Free user)", %{conn: conn} do
      free_user = insert(:user)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/connections/pat")
        |> assign(:current_user, free_user)
        |> EnforcePatCreation.call([])

      assert conn.halted
      assert conn.status == 402
      body = Phoenix.ConnTest.json_response(conn, 402)
      assert body["error"] == "pat_disabled_on_free"
      assert body["upgrade_url"] == "/settings/billing"
    end

    test "passes through when api_write_enabled is true (override grant)", %{conn: conn} do
      paid_user = insert(:user)

      insert(:user_limit_override,
        user: paid_user,
        key: "api_write_enabled",
        value: %{"v" => true}
      )

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/connections/pat")
        |> assign(:current_user, paid_user)
        |> EnforcePatCreation.call([])

      refute conn.halted
    end

    test "raises if :current_user is not assigned (programmer error guard)", %{conn: conn} do
      assert_raise RuntimeError, ~r/requires :current_user/, fn ->
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/connections/pat")
        |> EnforcePatCreation.call([])
      end
    end
  end
end
