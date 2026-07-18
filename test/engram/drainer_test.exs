defmodule Engram.DrainerTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  # drain/1 sets a NODE-GLOBAL :persistent_term draining flag; without this
  # reset it leaks into every test that runs after this file (review
  # 2026-07-15: DrainConnCloseTest went deterministically red and every later
  # ConnCase response got connection: close stamped).
  setup do
    on_exit(fn -> Engram.Drainer.reset_draining_for_test() end)
    :ok
  end

  test "drain/1 pauses oban and does NOT disconnect peers (fan-out must survive the socket drain)" do
    test_pid = self()

    opts = [
      pause_oban: fn -> send(test_pid, :oban_paused) end,
      disconnect: fn node -> send(test_pid, {:disconnected, node}) end,
      grace_ms: 0
    ]

    assert :ok = Engram.Drainer.drain(opts)

    assert_receive :oban_paused
    refute_receive {:disconnected, _}
  end

  test "disconnect_peers/1 disconnects each peer node, in order" do
    test_pid = self()

    opts = [
      peers: fn -> [:"a@1.1.1.1", :"b@2.2.2.2"] end,
      disconnect: fn node -> send(test_pid, {:disconnected, node}) end
    ]

    assert :ok = Engram.Drainer.disconnect_peers(opts)

    assert_receive {:disconnected, :"a@1.1.1.1"}
    assert_receive {:disconnected, :"b@2.2.2.2"}
  end

  test "disconnect_peers/1 is no-op-safe when there are no peers" do
    assert :ok = Engram.Drainer.disconnect_peers(peers: fn -> [] end, disconnect: fn _ -> :ok end)
  end

  test "default pause path pauses only the local node (local_only: true)" do
    # Regression guard for the cluster-wide-pause bug: a draining node must
    # pause ONLY its own queues. Without local_only: true, Oban broadcasts the
    # pause over the Postgres notifier to every node on the instance, so a
    # rolling deploy's draining task pauses the freshly-booted tasks too and
    # they never resume.
    Application.put_env(:engram, :oban_facade, Engram.ObanFacadeMock)
    on_exit(fn -> Application.delete_env(:engram, :oban_facade) end)

    test_pid = self()

    expect(Engram.ObanFacadeMock, :pause_all_queues, fn Oban, call_opts ->
      send(test_pid, {:paused, call_opts})
      :ok
    end)

    # No :pause_oban override → exercises the production default_pause_oban/0.
    assert :ok = Engram.Drainer.drain(grace_ms: 0)

    assert_receive {:paused, call_opts}
    assert Keyword.get(call_opts, :local_only) == true
  end
end
