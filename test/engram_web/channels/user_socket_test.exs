defmodule EngramWeb.UserSocketTest do
  use EngramWeb.ChannelCase, async: true
  import ExUnit.CaptureLog
  require Logger

  alias EngramWeb.UserSocket

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
  end

  test "connect still works with no conn params (backward compatible)", %{token: token} do
    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.conn_id == nil
  end
end
