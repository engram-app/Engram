defmodule EngramWeb.Plugs.EnforceDeviceCapTest do
  use EngramWeb.ConnCase, async: false

  import Engram.Factory

  alias Engram.Auth.DeviceFlow
  alias EngramWeb.Plugs.EnforceDeviceCap

  # Build a minimal Plug.Conn with :current_user assigned, without going
  # through the full router pipeline.
  defp conn_with_user(user) do
    build_conn()
    |> Map.put(:assigns, %{current_user: user})
  end

  # Pin upgrade_url for assertions; default is nil in test env.
  setup do
    prev = Application.get_env(:engram, :upgrade_url)
    Application.put_env(:engram, :upgrade_url, "https://app.engram.page/settings/billing")
    on_exit(fn -> Application.put_env(:engram, :upgrade_url, prev) end)
    :ok
  end

  describe "EnforceDeviceCap.call/2" do
    test "passes through when limit is nil (paid tier = unlimited)" do
      # starter tier has concurrent_devices: nil → treated as unlimited
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "active")

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])
      refute result.halted
    end

    test "passes through when override value is -1 (unlimited sentinel)" do
      # -1 is the canonical unlimited sentinel; cap_json/-1 → nil on the
      # wire, and the plug must treat it the same as :unlimited / nil.
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => -1}
      )

      # Existing connection: even with one live device family, -1 should
      # still pass through.
      insert(:device_refresh_token, user: user, vault: vault)

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])
      refute result.halted
    end

    test "passes through when current count is below the limit" do
      user = insert(:user)
      # Set cap to 3 — user has 0 active device connections
      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 3}
      )

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])
      refute result.halted
    end

    test "halts 402 with concurrent_devices_exceeded when user is at cap (no recent swap)" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Cap = 1, and we insert 1 active device token family. No recent
      # revoke → plain at-cap reason.
      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 1}
      )

      insert(:device_refresh_token, user: user, vault: vault)

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])

      assert result.halted
      assert result.status == 402

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "concurrent_devices_exceeded"
      assert body["limit_key"] == "concurrent_devices"
      assert body["limit"] == 1
      assert body["current"] == 1
      assert body["upgrade_url"] == "https://app.engram.page/settings/billing"
    end

    test "halts 402 with device_swap_cooldown when at cap and a recent revoke is within the window" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 1}
      )

      # Cooldown of 12h; revoke happened 2h ago → 10h remaining.
      insert(:user_limit_override,
        user: user,
        key: "device_swap_cooldown_hours",
        value: %{"v" => 12}
      )

      revoked_at =
        DateTime.utc_now()
        |> DateTime.add(-2 * 3600, :second)
        |> DateTime.truncate(:second)

      insert(:device_refresh_token, user: user, vault: vault, revoked_at: revoked_at)
      # Still at cap from a second active family.
      insert(:device_refresh_token, user: user, vault: vault)

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])

      assert result.halted
      assert result.status == 402

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "device_swap_cooldown"
      assert body["limit_key"] == "device_swap_cooldown_hours"
      assert body["limit"] == 12
      # Should be roughly 10 hours remaining (allow tiny clock skew).
      assert body["current"] in [10, 11]
      assert body["upgrade_url"] == "https://app.engram.page/settings/billing"
    end

    test "halts 402 with concurrent_devices_exceeded when recent revoke is past the cooldown window" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 1}
      )

      insert(:user_limit_override,
        user: user,
        key: "device_swap_cooldown_hours",
        value: %{"v" => 12}
      )

      # Revoke 24h ago — well past the 12h window.
      revoked_at =
        DateTime.utc_now()
        |> DateTime.add(-24 * 3600, :second)
        |> DateTime.truncate(:second)

      insert(:device_refresh_token, user: user, vault: vault, revoked_at: revoked_at)
      insert(:device_refresh_token, user: user, vault: vault)

      conn = conn_with_user(user)
      result = EnforceDeviceCap.call(conn, [])

      assert result.halted
      body = Jason.decode!(result.resp_body)
      assert body["reason"] == "concurrent_devices_exceeded"
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

    test "returns 402 concurrent_devices_exceeded when user is at concurrent_devices cap",
         %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      # Cap = 1, already at limit
      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 1}
      )

      insert(:device_refresh_token, user: user, vault: vault)

      {:ok, auth} = DeviceFlow.start_device_flow("plugin-client")

      conn =
        conn
        |> jwt_authed_conn(user)
        |> post("/api/auth/device/authorize", %{
          user_code: auth.user_code,
          vault_id: vault.id
        })

      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "concurrent_devices_exceeded"
      assert body["limit_key"] == "concurrent_devices"
    end

    test "returns 402 device_swap_cooldown when at cap and a recent revoke is in the window",
         %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 1}
      )

      insert(:user_limit_override,
        user: user,
        key: "device_swap_cooldown_hours",
        value: %{"v" => 12}
      )

      revoked_at =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      insert(:device_refresh_token, user: user, vault: vault, revoked_at: revoked_at)
      insert(:device_refresh_token, user: user, vault: vault)

      {:ok, auth} = DeviceFlow.start_device_flow("plugin-client")

      conn =
        conn
        |> jwt_authed_conn(user)
        |> post("/api/auth/device/authorize", %{
          user_code: auth.user_code,
          vault_id: vault.id
        })

      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "device_swap_cooldown"
      assert body["limit_key"] == "device_swap_cooldown_hours"
      assert body["limit"] == 12
      assert is_integer(body["current"]) and body["current"] > 0
    end

    test "returns 200 when user is below the cap", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      insert(:user_limit_override,
        user: user,
        key: "concurrent_devices",
        value: %{"v" => 2}
      )

      # 0 existing device connections → below cap of 2
      {:ok, auth} = DeviceFlow.start_device_flow("plugin-client")

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
