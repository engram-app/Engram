defmodule EngramWeb.CrdtChannelRelayTest do
  @moduledoc """
  `relay_frame/2` against a room that is already gone.

  Driven directly rather than through a channel on purpose. The failure this
  covers is a RACE — a frame arriving after the room died but before the
  channel's `:DOWN` evicted the cached pid — and the existing channel-level
  test for room death has to `Process.sleep(50)` to let that `:DOWN` land, i.e.
  it deliberately steps around this window. A test that tried to land inside it
  through `push/3` could only ever be timing-dependent, and one that fails to
  hit the window would pass while proving nothing.

  Cross-node this window is not small: rooms are `:global` singletons, so the
  room is routinely on another node, and when that node drains the monitor
  `:DOWN` arrives over distribution while frames keep arriving from the client.
  That is the 2026-08-18 production signature — a full-vault download to mobile
  died mid-transfer when its channel called into a room on a task that had just
  been replaced.
  """
  use ExUnit.Case, async: true

  alias EngramWeb.CrdtChannel

  # A sync_step1 frame, and it MUST be step1 rather than an update.
  #
  # y_ex dispatches by frame type (deps/y_ex/lib/server/doc_server_worker.ex):
  # sync_step1 `<<0,0,…>>` is a `GenServer.call` and EXITS against a dead pid,
  # while sync_update `<<0,2,…>>` is a `GenServer.cast` and returns `:ok`
  # having silently dropped the frame. An update frame here would make every
  # assertion below pass against the UNFIXED code — vacuously.
  #
  # The production trace confirms the call path: `{:__yex_sync_step1_raw, …}`.
  @frame <<0, 0, 1, 0>>

  # The cast counterpart, used only to pin the contrast.
  @update_frame <<0, 2, 1, 0>>

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    refute Process.alive?(pid)
    pid
  end

  test "returns :room_unavailable instead of exiting when the room is dead" do
    # y_ex dispatches sync frames as a GenServer.call, which EXITS the caller
    # against a dead pid. Uncaught, that exit kills the channel process and
    # every note syncing over it, not just this frame.
    assert {:error, :room_unavailable} = CrdtChannel.relay_frame(dead_pid(), @frame)
  end

  test "the caller survives — the exit is caught, not merely re-shaped" do
    # The point is process survival, so assert it directly: a `catch` that
    # re-raised, or a rescue that missed `:exit`, would still take the caller
    # down while satisfying the assertion above under a different shape.
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:result, CrdtChannel.relay_frame(dead_pid(), @frame)})
        # Stay alive so the test can observe that we were not killed by the call.
        receive do: (:stop -> :ok)
      end)

    assert_receive {:result, {:error, :room_unavailable}}, 2_000
    assert Process.alive?(caller), "relay_frame took its caller down with the dead room"
    send(caller, :stop)
  end

  test "a live room still relays normally" do
    # Guard against 'fixing' this by making relay_frame always return an error.
    {:ok, room} = Yex.Sync.SharedDoc.start_link(doc_name: "relay-test-#{System.unique_integer()}")
    # start_link links to the test process, so kill it via an unlinked teardown
    # rather than taking this test down with it.
    on_exit(fn -> if Process.alive?(room), do: Process.exit(room, :kill) end)
    Process.unlink(room)

    assert :ok = CrdtChannel.relay_frame(room, @frame)
  end

  test "a dead room's UPDATE frame is still silently accepted (known cast path)" do
    # Not something this change fixes, pinned so the asymmetry is visible: an
    # update is a cast, so it reports success while dropping the edit. That
    # silent-drop class is what the room monitor + cache eviction exist to
    # bound, and it is why the drain releases observers rather than stopping
    # rooms outright. If this ever starts returning an error, the dispatch
    # contract changed and relay_frame's reasoning needs revisiting.
    assert :ok = CrdtChannel.relay_frame(dead_pid(), @update_frame)
  end
end
