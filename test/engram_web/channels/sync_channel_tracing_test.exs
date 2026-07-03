defmodule EngramWeb.SyncChannelTracingTest do
  # async: false. The setup mutates the global Logger level to :info; every
  # other test that does this is async: false to avoid corrupting concurrent
  # async modules (e.g. sync_channel_test) that rely on the default :warning.
  # ExUnit.CaptureLog's own `:level` option only restricts capture; it does
  # NOT override `Logger.level/0`, so the global level must be raised too
  # (mirrors user_socket_test.exs from Task A3).
  use EngramWeb.ChannelCase, async: false
  import ExUnit.CaptureLog
  require Logger

  alias EngramWeb.UserSocket

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, token, _} = Engram.Accounts.create_api_key(user, "tracing-test")
    topic = "sync:#{user.id}:#{vault.id}"
    %{user: user, vault: vault, token: token, topic: topic}
  end

  defp join_socket(token, topic, conn_id, device_id) do
    {:ok, socket} =
      connect(UserSocket, %{
        "token" => token,
        "conn_id" => conn_id,
        "device_id" => device_id
      })

    subscribe_and_join(socket, topic, %{})
  end

  test "logs sync join with conn_id", %{token: token, topic: topic} do
    log =
      capture_log(fn ->
        {:ok, _reply, _socket} = join_socket(token, topic, "c1", "d1")
        # handle_info({:after_join, ...}) runs async after the join reply,
        # so give the channel process time to log before the window closes.
        Process.sleep(50)
      end)

    assert log =~ "sync join"
    assert log =~ "c1"
  end

  test "warns when the same device opens a second live channel",
       %{token: token, topic: topic} do
    {:ok, _r, _s1} = join_socket(token, topic, "c1", "same-device")
    # allow the first presence to register
    Process.sleep(150)

    log =
      capture_log(fn ->
        {:ok, _r, _s2} = join_socket(token, topic, "c2", "same-device")
        Process.sleep(150)
      end)

    assert log =~ "duplicate live channel"
    assert log =~ "c2"
  end

  test "logs sync leave on terminate", %{token: token, topic: topic} do
    {:ok, _r, socket} = join_socket(token, topic, "c1", "d1")

    log =
      capture_log(fn ->
        Process.unlink(socket.channel_pid)
        ref = Process.monitor(socket.channel_pid)
        leave(socket)
        assert_receive {:DOWN, ^ref, :process, _, _}, 1000
        Process.sleep(50)
      end)

    assert log =~ "sync leave"
    assert log =~ "c1"
  end
end
