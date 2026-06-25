defmodule Engram.DrainerTest do
  use ExUnit.Case, async: true

  test "drain/1 pauses oban, then disconnects each peer node, in order" do
    test_pid = self()

    opts = [
      pause_oban: fn -> send(test_pid, :oban_paused) end,
      peers: fn -> [:"a@1.1.1.1", :"b@2.2.2.2"] end,
      disconnect: fn node -> send(test_pid, {:disconnected, node}) end,
      grace_ms: 0
    ]

    assert :ok = Engram.Drainer.drain(opts)

    assert_receive :oban_paused
    assert_receive {:disconnected, :"a@1.1.1.1"}
    assert_receive {:disconnected, :"b@2.2.2.2"}
  end

  test "drain/1 is no-op-safe when there are no peers" do
    opts = [
      pause_oban: fn -> :ok end,
      peers: fn -> [] end,
      disconnect: fn _ -> :ok end,
      grace_ms: 0
    ]

    assert :ok = Engram.Drainer.drain(opts)
  end
end
