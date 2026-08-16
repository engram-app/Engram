defmodule EngramWeb.UserSocketTest do
  # async: false. The setup mutates the global Logger level to :info; every
  # other test that does this is async: false to avoid corrupting concurrent
  # async modules (e.g. sync_channel_test) that rely on the default :warning.
  use EngramWeb.ChannelCase, async: false
  import ExUnit.CaptureLog

  alias EngramWeb.UserSocket

  require Logger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "socket-test")
    %{user: user, token: api_key}
  end

  test "connect stores conn_id/device_id and logs ws connect", %{token: token} do
    log =
      capture_log(fn ->
        assert {:ok, socket} =
                 connect(UserSocket, %{
                   "token" => token,
                   "conn_id" => "conn-abc",
                   "device_id" => "dev-1",
                   "vault_id" => "vault-9"
                 })

        assert socket.assigns.conn_id == "conn-abc"
        assert socket.assigns.device_id == "dev-1"
      end)

    assert log =~ "ws connect"
    assert log =~ "conn-abc"

    # Phoenix's own "CONNECTED TO ... Parameters:" line renders the connect
    # params. RedactFilter cannot help here — it scrubs metadata, never the
    # message body — so the only control is :filter_parameters. This asserts
    # the credential itself, not the presence of "[FILTERED]", because a
    # future refactor could drop the line entirely and should still pass.
    refute log =~ token
  end

  # Phoenix matches filter_parameters by SUBSTRING on the key, so the entries
  # are prefixes/fragments, not names. "token" does NOT cover device_code —
  # which redeems into both an access and a refresh token, and so is a bearer
  # credential in its own right for its 300s life.
  test "filters credential-bearing param names, not just exact matches", %{token: token} do
    log =
      capture_log(fn ->
        assert {:ok, _socket} =
                 connect(UserSocket, %{
                   "token" => token,
                   "device_code" => "dev-code-secret",
                   "code_verifier" => "pkce-secret"
                 })
      end)

    refute log =~ "dev-code-secret"
    refute log =~ "pkce-secret"
  end

  test "connect still works with no conn params (backward compatible)", %{token: token} do
    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.conn_id == nil
  end
end
