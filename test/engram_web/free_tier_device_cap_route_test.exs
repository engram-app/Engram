defmodule EngramWeb.FreeTierDeviceCapRouteTest do
  @moduledoc """
  Route-level proof that `concurrent_devices` and `device_swap_cooldown_hours`
  refuse from `POST /api/auth/device/authorize`.

  `EnforceDeviceCapTest` calls `EnforceDeviceCap.call/2` on a conn it assigns
  `:current_user` onto by hand. That proves the arithmetic and never that the
  plug is reachable — the same gap that let `EnforceSearchCap` sit on the shared
  pipeline doing nothing for the entire MCP transport (engram#1527).

  `DeviceAuthControllerTest` drives this route 18 times and never puts a user
  over the cap, so before this file the refusal had no route-level proof at all.
  """
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, raw_key, _} = Engram.Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{raw_key}")

    %{conn: authed, user: user, vault: vault}
  end

  defp cap!(user, key, n),
    do: insert(:user_limit_override, user: user, key: key, value: %{"v" => n})

  defp authorize(conn, user_code, vault),
    do: post(conn, "/api/auth/device/authorize", %{user_code: user_code, vault_id: vault.id})

  defp start_flow do
    {:ok, auth} = Engram.Auth.DeviceFlow.start_device_flow("test_client")
    auth
  end

  test "at the concurrent_devices cap the route refuses", %{conn: conn, user: user, vault: vault} do
    cap!(user, "concurrent_devices", 1)
    # One live device family == at the cap of 1.
    insert(:device_refresh_token, user: user, vault: vault)

    body = json_response(authorize(conn, start_flow().user_code, vault), 402)

    assert body["limit_key"] == "concurrent_devices"
    assert body["error"] == "limit_exceeded"
    assert Map.has_key?(body, "upgrade_url")
  end

  test "under the cap the same route still authorizes", %{conn: conn, user: user, vault: vault} do
    cap!(user, "concurrent_devices", 2)
    insert(:device_refresh_token, user: user, vault: vault)

    # Proves the 402 above comes from the CAP and not from something else in
    # this request shape — without it, a broken fixture reads as enforcement.
    assert json_response(authorize(conn, start_flow().user_code, vault), 200)
  end

  test "inside the swap cooldown the route refuses with the cooldown key", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    cap!(user, "concurrent_devices", 1)
    cap!(user, "device_swap_cooldown_hours", 24)

    # At cap AND a family revoked just now: the cooldown branch wins over the
    # plain at-cap reason, which is the distinction the plug exists to make.
    insert(:device_refresh_token, user: user, vault: vault)

    insert(:device_refresh_token,
      user: user,
      vault: vault,
      revoked_at: DateTime.utc_now(:second)
    )

    body = json_response(authorize(conn, start_flow().user_code, vault), 402)

    assert body["limit_key"] == "device_swap_cooldown_hours"
  end
end
