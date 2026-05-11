defmodule EngramWeb.DeviceAuthControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Auth.DeviceFlow

  defp create_authed_conn(%{conn: conn}) do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test")
    authed_conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")

    %{conn: conn, authed_conn: authed_conn, user: user}
  end

  describe "POST /api/auth/device (start flow)" do
    test "returns device_code, user_code, and verification_url", %{conn: conn} do
      conn = post(conn, "/api/auth/device", %{client_id: "test_client"})
      resp = json_response(conn, 200)

      assert is_binary(resp["device_code"])
      assert String.match?(resp["user_code"], ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/)
      assert is_binary(resp["verification_url"])
      assert resp["verification_url"] =~ ~r{/link$}
      refute resp["verification_url"] =~ "/app/"
      assert resp["expires_in"] == 300
      assert resp["interval"] == 5
    end
  end

  describe "POST /api/auth/device/authorize" do
    setup :create_authed_conn

    test "authorizes with valid user_code and vault", %{authed_conn: conn, user: user} do
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      conn =
        post(conn, "/api/auth/device/authorize", %{user_code: auth.user_code, vault_id: vault.id})

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "creates new vault when vault_id is 'new'", %{authed_conn: conn} do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      conn =
        post(conn, "/api/auth/device/authorize", %{
          user_code: auth.user_code,
          vault_id: "new",
          vault_name: "My New Vault"
        })

      assert %{"ok" => true, "vault_id" => vault_id} = json_response(conn, 200)
      assert is_integer(vault_id)
    end

    test "rejects invalid user_code", %{authed_conn: conn} do
      conn = post(conn, "/api/auth/device/authorize", %{user_code: "XXXX-YYYY", vault_id: 1})
      assert json_response(conn, 404)
    end

    test "rejects unauthenticated request", %{conn: conn} do
      conn = post(conn, "/api/auth/device/authorize", %{user_code: "XXXX-YYYY", vault_id: 1})
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/auth/device/token (poll)" do
    test "returns authorization_pending for pending code", %{conn: conn} do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")

      conn = post(conn, "/api/auth/device/token", %{device_code: auth.device_code})
      assert %{"error" => "authorization_pending"} = json_response(conn, 428)
    end

    test "returns tokens for authorized code", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      conn = post(conn, "/api/auth/device/token", %{device_code: auth.device_code})
      resp = json_response(conn, 200)

      assert is_binary(resp["access_token"])
      assert String.starts_with?(resp["refresh_token"], "engram_rt_")
      assert resp["vault_id"] == vault.id
      assert resp["user_email"] == user.email
      assert resp["expires_in"] == Engram.Token.ttl_seconds()
    end

    test "returns expired for consumed code", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, _} = DeviceFlow.exchange_device_code(auth.device_code)

      conn = post(conn, "/api/auth/device/token", %{device_code: auth.device_code})
      assert %{"error" => "expired_or_invalid"} = json_response(conn, 410)
    end
  end

  describe "POST /api/auth/token/refresh" do
    test "returns new token pair", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, tokens} = DeviceFlow.exchange_device_code(auth.device_code)

      conn = post(conn, "/api/auth/token/refresh", %{refresh_token: tokens.refresh_token})
      resp = json_response(conn, 200)

      assert is_binary(resp["access_token"])
      assert is_binary(resp["refresh_token"])
      assert resp["refresh_token"] != tokens.refresh_token
      assert resp["expires_in"] == Engram.Token.ttl_seconds()
    end

    test "rejects revoked refresh token", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      {:ok, tokens} = DeviceFlow.exchange_device_code(auth.device_code)
      {:ok, _} = DeviceFlow.refresh_access_token(tokens.refresh_token)

      conn = post(conn, "/api/auth/token/refresh", %{refresh_token: tokens.refresh_token})
      assert json_response(conn, 401)
    end
  end
end
