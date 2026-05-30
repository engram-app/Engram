defmodule EngramWeb.Plugs.EnforceDeviceCapTest do
  use EngramWeb.ConnCase, async: false

  import Engram.Factory

  alias EngramWeb.Plugs.EnforceDeviceCap

  # Build a minimal Plug.Conn with :current_user assigned, without going
  # through the full router pipeline.
  defp conn_with_user(user) do
    build_conn()
    |> Map.put(:assigns, %{current_user: user})
  end

  describe "EnforceDeviceCap.call/2" do
    test "passes through when limit is nil (paid tier = unlimited)" do
      # starter tier has obsidian_connections_cap: nil → treated as unlimited
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "active")

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])
      refute result.halted
    end

    test "passes through when current count is below the limit" do
      user = insert(:user)
      # Set cap to 3 — user has 0 active device connections
      insert(:user_limit_override,
        user: user,
        key: "obsidian_connections_cap",
        value: %{"v" => 3}
      )

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])
      refute result.halted
    end

    test "halts with 402 when user is at cap" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Cap = 1, and we insert 1 active device token family
      insert(:user_limit_override,
        user: user,
        key: "obsidian_connections_cap",
        value: %{"v" => 1}
      )

      insert(:device_refresh_token, user: user, vault: vault)

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])

      assert result.halted
      assert result.status == 402

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "connection_cap_reached"
      assert body["kind"] == "obsidian"
      assert body["current"] == 1
      assert body["limit"] == 1
      assert body["upgrade_url"] == "/settings/billing"
    end

    test "raises when :current_user is not assigned" do
      conn = build_conn()

      assert_raise RuntimeError, ~r/EnforceDeviceCap requires :current_user/, fn ->
        EnforceDeviceCap.call(conn, [])
      end
    end
  end

  describe "POST /api/auth/device/authorize integration" do
    # Reuse the jwt_authed helper pattern from device_auth_controller_test
    defp jwt_authed_conn(conn, user) do
      user = ensure_external_id(user)
      {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
      put_req_header(conn, "authorization", "Bearer #{token}")
    end

    defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "",
      do: user

    defp ensure_external_id(user) do
      {:ok, updated} =
        user
        |> Ecto.Changeset.change(external_id: "test-#{user.id}")
        |> Engram.Repo.update(skip_tenant_check: true)

      updated
    end

    test "returns 402 when user is at obsidian_connections_cap", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Cap = 1, already at limit
      insert(:user_limit_override,
        user: user,
        key: "obsidian_connections_cap",
        value: %{"v" => 1}
      )

      insert(:device_refresh_token, user: user, vault: vault)

      {:ok, auth} = Engram.Auth.DeviceFlow.start_device_flow("plugin-client")

      conn =
        conn
        |> jwt_authed_conn(user)
        |> post("/api/auth/device/authorize", %{
          user_code: auth.user_code,
          vault_id: vault.id
        })

      body = json_response(conn, 402)
      assert body["error"] == "connection_cap_reached"
      assert body["kind"] == "obsidian"
    end

    test "returns 200 when user is below the cap", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "obsidian_connections_cap",
        value: %{"v" => 2}
      )

      # 0 existing device connections → below cap of 2
      {:ok, auth} = Engram.Auth.DeviceFlow.start_device_flow("plugin-client")

      conn =
        conn
        |> jwt_authed_conn(user)
        |> post("/api/auth/device/authorize", %{
          user_code: auth.user_code,
          vault_id: vault.id
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end
  end
end
