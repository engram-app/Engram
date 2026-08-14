defmodule Engram.Notes.CrdtRoomLruTest do
  @moduledoc """
  The backstop half of #1152.

  Idle-exit bounds rooms that go QUIET. It does nothing for a room that is
  continuously active, so a pathological mix of busy vaults still pins memory —
  #1149 measured 7.91 MB resident per 10k-note vault against a 1024 MB task.
  The LRU forces the least-recently-active rooms out under pressure.

  It forces a DRAIN, never a kill: draining is the one release path proven not
  to eat an in-flight `sync_update` (see CrdtChannelDrainTest). The LRU
  deliberately bypasses `idle?/2` — evicting rooms that are NOT idle is its
  entire purpose — which is exactly why it must reuse the safe mechanism.
  """
  use Engram.DataCase, async: false

  alias Engram.Notes.{CrdtRegistry, CrdtRoomLru}

  describe "select_evictions/2 (pure)" do
    # Entries are {note_id, pid, last_activity_monotonic}; smaller = older.
    defp entry(id, age), do: {id, self(), age}

    test "nothing is evicted while resident count is within the cap" do
      entries = [entry("a", 100), entry("b", 200)]
      assert CrdtRoomLru.select_evictions(entries, 5) == []
    end

    test "evicts the least-recently-active first, and only the excess" do
      entries = [entry("new", 300), entry("oldest", 100), entry("mid", 200)]

      assert CrdtRoomLru.select_evictions(entries, 2) == ["oldest"]
    end

    test "evicts enough to reach the cap, not just one" do
      entries = for n <- 1..10, do: entry("n#{n}", n)

      evicted = CrdtRoomLru.select_evictions(entries, 4)

      assert length(evicted) == 6
      assert "n1" in evicted
      assert "n6" in evicted
      refute "n7" in evicted, "the 4 most recently active must survive"
    end

    test "a cap of zero evicts everything rather than crashing" do
      assert length(CrdtRoomLru.select_evictions([entry("a", 1), entry("b", 2)], 0)) == 2
    end
  end

  describe "sweep" do
    setup do
      CrdtRoomLru.reset()
      on_exit(&CrdtRoomLru.reset/0)
      :ok
    end

    test "a room over the cap is asked to DRAIN, never killed" do
      # Two live processes standing in for rooms; the LRU only ever broadcasts,
      # so it does not need real SharedDocs.
      old = spawn(fn -> Process.sleep(:infinity) end)
      new = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Enum.each([old, new], &Process.exit(&1, :kill)) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic("old-note"))

      CrdtRoomLru.touch("old-note", old)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new)

      CrdtRoomLru.sweep(1)

      assert_receive {:crdt_room_drain, ^old}, 1_000
      assert Process.alive?(old), "the LRU must drain, not kill — a kill eats in-flight edits"
    end

    test "the most recently active room is left alone" do
      old = spawn(fn -> Process.sleep(:infinity) end)
      new = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Enum.each([old, new], &Process.exit(&1, :kill)) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic("new-note"))

      CrdtRoomLru.touch("old-note", old)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new)

      CrdtRoomLru.sweep(1)

      refute_receive {:crdt_room_drain, ^new}, 300
    end

    test "activity moves a room to the back of the eviction queue" do
      a = spawn(fn -> Process.sleep(:infinity) end)
      b = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Enum.each([a, b], &Process.exit(&1, :kill)) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic("b-note"))

      CrdtRoomLru.touch("a-note", a)
      Process.sleep(5)
      CrdtRoomLru.touch("b-note", b)
      Process.sleep(5)
      # `a` is used again, so `b` becomes the least recently active.
      CrdtRoomLru.touch("a-note", a)

      CrdtRoomLru.sweep(1)

      assert_receive {:crdt_room_drain, ^b}, 1_000
    end

    test "a dead room is pruned instead of counting toward the cap" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      live = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(live, :kill) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic("live-note"))

      CrdtRoomLru.touch("dead-note", dead)
      Process.sleep(5)
      CrdtRoomLru.touch("live-note", live)

      # Cap of 1 with one DEAD entry: pruning must satisfy the cap on its own,
      # leaving the live room untouched. Counting corpses toward residency
      # would evict healthy rooms to make room for memory nothing is using.
      CrdtRoomLru.sweep(1)

      refute_receive {:crdt_room_drain, ^live}, 300
      assert CrdtRoomLru.resident_count() == 1
    end
  end
end
