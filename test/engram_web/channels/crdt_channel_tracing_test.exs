defmodule EngramWeb.CrdtChannelTracingTest do
  # async: false. The setup mutates the global Logger level to :info; every
  # other test that does this is async: false to avoid corrupting concurrent
  # async modules (e.g. crdt_channel_test) that rely on the default :warning.
  # ExUnit.CaptureLog's own `:level` option only restricts capture; it does
  # NOT override `Logger.level/0`, so the global level must be raised too
  # (mirrors sync_channel_tracing_test.exs from Task A4).
  use EngramWeb.ChannelCase, async: false
  import ExUnit.CaptureLog

  alias EngramWeb.UserSocket

  require Logger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, token, _} = Engram.Accounts.create_api_key(user, "crdt-tracing-test")
    topic = "crdt:#{user.id}:#{vault.id}"
    %{user: user, vault: vault, token: token, topic: topic}
  end

  defp join_socket(token, topic, conn_id, device_id) do
    {:ok, socket} =
      connect(UserSocket, %{
        "token" => token,
        "conn_id" => conn_id,
        "device_id" => device_id
      })

    subscribe_and_join(socket, topic, %{"crdt_proto" => 2})
  end

  test "logs crdt join with conn_id", %{token: token, topic: topic} do
    log =
      capture_log(fn ->
        {:ok, _reply, _socket} = join_socket(token, topic, "c9", "d9")
      end)

    assert log =~ "crdt join"
    assert log =~ "c9"
  end

  test "logs crdt leave on terminate", %{token: token, topic: topic} do
    {:ok, _r, socket} = join_socket(token, topic, "c1", "d1")

    log =
      capture_log(fn ->
        Process.unlink(socket.channel_pid)
        ref = Process.monitor(socket.channel_pid)
        leave(socket)
        assert_receive {:DOWN, ^ref, :process, _, _}, 1000
        Process.sleep(50)
      end)

    assert log =~ "crdt leave"
    assert log =~ "c1"
  end
end
