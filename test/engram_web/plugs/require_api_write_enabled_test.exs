defmodule EngramWeb.Plugs.RequireApiWriteEnabledTest do
  # async: false — flips Application env :limits_enforced inside one branch.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.RequireApiWriteEnabled

  setup do
    user = insert(:user)
    api_key = %Engram.Accounts.ApiKey{id: 1, user_id: user.id, name: "test"}
    %{user: user, api_key: api_key}
  end

  describe "GET / HEAD (read paths)" do
    test "passes through GET without auth check", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "GET")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end

    test "passes through HEAD without auth check", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "HEAD")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end
  end

  describe "JWT-authed (no current_api_key) writes" do
    test "passes through — web app is exempt from this gate", %{conn: conn, user: user} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/notes")
        |> assign(:current_user, user)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end
  end

  describe "API-key-authed writes — Free user (api_write_enabled=false)" do
    test "halts 402 on POST /api/notes", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/notes")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      assert conn.halted
      assert conn.status == 402
      body = Phoenix.ConnTest.json_response(conn, 402)
      assert body["error"] == "api_write_not_available"
      assert body["upgrade_url"] == "/billing"
    end

    test "halts 402 on DELETE /api/notes/foo", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "DELETE")
        |> Map.put(:request_path, "/api/notes/foo")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      assert conn.halted
      assert conn.status == 402
    end

    test "halts 402 on POST /api/attachments", %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/attachments")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      assert conn.halted
      assert conn.status == 402
    end

    test "passes through POST /api/search (read-via-POST exemption)",
         %{conn: conn, user: user, api_key: api_key} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/search")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end
  end

  describe "API-key-authed writes — Starter / Pro user (api_write_enabled=true)" do
    test "passes through when override grants the feature",
         %{conn: conn, user: user, api_key: api_key} do
      insert(:user_limit_override,
        user: user,
        key: "api_write_enabled",
        value: %{"v" => true}
      )

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/notes")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end
  end

  describe "self-host bypass" do
    test "passes through when limits_enforced=false (Paddle key unset)",
         %{conn: conn, user: user, api_key: api_key} do
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, true) end)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/notes")
        |> assign(:current_user, user)
        |> assign(:current_api_key, api_key)
        |> RequireApiWriteEnabled.call([])

      refute conn.halted
    end
  end
end
