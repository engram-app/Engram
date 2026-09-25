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

  @vault "vault-1"

  describe "select_evictions/2 (pure)" do
    # Entries are {note_id, pid, vault_id, last_activity_monotonic}; smaller = older.
    defp entry(id, age), do: {id, self(), @vault, age}

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

    # 2026-09-14: one import put 1,175 rooms resident against a cap of 64 while
    # a flat 16-per-sweep pace reclaimed them over ten minutes. Unpaced is the
    # default; pacing is the fallback for when drains are not landing.
    test "evicts ALL of a large excess in one pass" do
      entries = for n <- 1..100, do: entry("n#{n}", n)

      assert length(CrdtRoomLru.select_evictions(entries, 10)) == 90
    end

    test "an explicit limit paces the pass" do
      entries = for n <- 1..100, do: entry("n#{n}", n)

      evicted = CrdtRoomLru.select_evictions(entries, 10, 16)

      assert length(evicted) == 16
      assert "n1" in evicted
      refute "n17" in evicted, "a paced pass still takes the OLDEST first"
    end

    defp entry(id, vault, age), do: {id, self(), vault, age}

    defp per_vault(entries, evicted) do
      entries
      |> Enum.reject(fn {id, _, _, _} -> id in evicted end)
      |> Enum.frequencies_by(fn {_, _, vault, _} -> vault end)
    end

    # #1412: a bulk sync by one user must not evict the rooms another user is
    # typing in. Pure recency would take `quiet`'s two rooms first — they are
    # the oldest on the node — even though `bulk` is the vault over its share.
    test "sheds the vault holding the most rooms before touching a smaller one" do
      quiet = [entry("q1", "quiet", 1), entry("q2", "quiet", 2)]
      bulk = for n <- 1..10, do: entry("b#{n}", "bulk", 100 + n)

      evicted = CrdtRoomLru.select_evictions(quiet ++ bulk, 8)

      assert length(evicted) == 4
      assert Enum.all?(evicted, &String.starts_with?(&1, "b"))
      assert "b1" in evicted, "within a vault, the least recently active goes first"
    end

    test "levels the largest vaults down together rather than emptying one" do
      a = for n <- 1..6, do: entry("a#{n}", "A", n)
      b = for n <- 1..4, do: entry("b#{n}", "B", 10 + n)

      evicted = CrdtRoomLru.select_evictions(a ++ b, 6)

      assert per_vault(a ++ b, evicted) == %{"A" => 3, "B" => 3}
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

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("old-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new, @vault)

      CrdtRoomLru.sweep(1)

      assert_receive {:crdt_room_drain, ^old}, 1_000
      assert Process.alive?(old), "the LRU must drain, not kill — a kill eats in-flight edits"
    end

    test "the most recently active room is left alone" do
      old = spawn(fn -> Process.sleep(:infinity) end)
      new = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Enum.each([old, new], &Process.exit(&1, :kill)) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("old-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new, @vault)

      CrdtRoomLru.sweep(1)

      refute_receive {:crdt_room_drain, ^new}, 300
    end

    test "activity moves a room to the back of the eviction queue" do
      a = spawn(fn -> Process.sleep(:infinity) end)
      b = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Enum.each([a, b], &Process.exit(&1, :kill)) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("a-note", a, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("b-note", b, @vault)
      Process.sleep(5)
      # `a` is used again, so `b` becomes the least recently active.
      CrdtRoomLru.touch("a-note", a, @vault)

      CrdtRoomLru.sweep(1)

      assert_receive {:crdt_room_drain, ^b}, 1_000
    end

    test "a dead room is pruned instead of counting toward the cap" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      live = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(live, :kill) end)

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("dead-note", dead, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("live-note", live, @vault)

      # Cap of 1 with one DEAD entry: pruning must satisfy the cap on its own,
      # leaving the live room untouched. Counting corpses toward residency
      # would evict healthy rooms to make room for memory nothing is using.
      CrdtRoomLru.sweep(1)

      refute_receive {:crdt_room_drain, ^live}, 300
      assert CrdtRoomLru.resident_count() == 1
    end
  end

  describe "eviction accounting" do
    setup do
      CrdtRoomLru.reset()
      on_exit(&CrdtRoomLru.reset/0)

      test_pid = self()
      handler = "lru-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp live_room do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    # `lru_evicted` is the capacity signal an operator reads to decide whether
    # idle-exit is keeping up. Nothing asserted it was ever emitted.
    test "an eviction is counted under its own phase" do
      old = live_room()
      new = live_room()

      CrdtRoomLru.touch("old-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new, @vault)

      CrdtRoomLru.sweep(1)

      assert_receive {:drain_telemetry, %{count: 1}, %{phase: :lru_evicted}}, 1_000
    end

    # An ask is not an exit. A room whose observers never act keeps its old
    # timestamp, so it stays the OLDEST entry and is re-selected on every later
    # sweep — one stuck room monopolises the eviction slate, residency never
    # comes down, and the counter inflates with repeat asks for the same room.
    # Re-stamping on the ask moves it to the back of the queue.
    test "a room that ignores the drain does not monopolise the eviction slate" do
      # Grace 0: `a` counts as stuck by the second sweep, so it is a candidate
      # again. Inside the grace window it would not be re-asked at all.
      with_lru_config(drain_grace_ms: 0)
      a = live_room()
      b = live_room()
      c = live_room()

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("a-note", a, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("b-note", b, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("c-note", c, @vault)

      # Nobody observes these, so the drain changes nothing — the room stays.
      CrdtRoomLru.sweep(2)
      assert_receive {:crdt_room_drain, ^a}, 1_000

      CrdtRoomLru.sweep(2)
      assert_receive {:crdt_room_drain, ^b}, 1_000

      refute_received {:crdt_room_drain, ^a},
                      "`a` was asked again while `b` had never been asked at all"
    end

    # The pace exists for ONE case: drains that are not landing (a starved pool,
    # #1411), where every drain costs the owning channel a 1s probe. A room
    # still resident well after it was asked is that signal, and it drops the
    # next pass back to the paced limit.
    test "falls back to the paced limit when an earlier drain did not land" do
      with_lru_config(drain_grace_ms: 0)
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      for n <- 1..20, do: CrdtRoomLru.touch("first-#{n}", live_room(), @vault)
      CrdtRoomLru.sweep(0)
      assert drains_received() == 20, "no drain was outstanding, so the first pass is unpaced"

      # Nobody observes these rooms, so every drain above was ignored and all 20
      # are still alive — exactly what a wedged node looks like.
      CrdtRoomLru.sweep(0)
      assert drains_received() == 16
    end

    test "a drain still inside its grace window does not count as stuck" do
      with_lru_config(drain_grace_ms: 60_000)
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      for n <- 1..20, do: CrdtRoomLru.touch("r-#{n}", live_room(), @vault)
      CrdtRoomLru.sweep(0)
      assert drains_received() == 20

      # The first 20 are still inside their grace window: not stuck, so 20 NEW
      # rooms are evicted in one unpaced pass (more than the paced 16).
      for n <- 1..20, do: CrdtRoomLru.touch("s-#{n}", live_room(), @vault)
      CrdtRoomLru.sweep(0)
      assert drains_received() == 20
    end

    # A drained room takes a checkpoint to exit. A sweep that lands before it
    # does must neither re-ask it nor count it toward the excess — or, with the
    # asked rooms restamped to "now", it turns on the rooms it meant to KEEP.
    test "a room asked moments ago is not asked again and does not count toward the excess" do
      with_lru_config(drain_grace_ms: 60_000)
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      rooms = for n <- 1..5, do: {"r-#{n}", live_room()}

      for {id, pid} <- rooms do
        CrdtRoomLru.touch(id, pid, @vault)
        Process.sleep(2)
      end

      CrdtRoomLru.sweep(2)
      assert drains_received() == 3

      CrdtRoomLru.sweep(2)
      assert drains_received() == 0, "the 3 asked rooms are exiting; the 2 kept are the cap"

      # One NEW room: exactly one more over the cap, and the victim is the oldest
      # room that was never asked.
      [{_, kept_oldest} | _] = Enum.drop(rooms, 3)
      CrdtRoomLru.touch("r-new", live_room(), @vault)
      CrdtRoomLru.sweep(2)

      assert_receive {:crdt_room_drain, ^kept_oldest}, 1_000
      assert drains_received() == 0
    end

    # The paced limit bounds how much probe work a wedge can queue on a channel
    # per sweep INTERVAL. Prompt over-cap sweeps would re-run it every second.
    # Asserted on the scheduled timer, not on silence: the periodic sweep can
    # land inside any quiet window and drain a stuck room legitimately.
    test "no prompt sweep while drains are stuck; pacing waits for the interval" do
      with_lru_config(drain_grace_ms: 0, max_resident: 1, over_cap_sweep_ms: 60_000)

      for n <- 1..3, do: CrdtRoomLru.touch("w-#{n}", live_room(), @vault)
      CrdtRoomLru.sweep(1)
      # Nobody drained anything: the next sweep sees stuck rooms and paces.
      CrdtRoomLru.sweep(1)

      CrdtRoomLru.touch("w-new", live_room(), @vault)

      assert over_cap_timer() == nil
    end

    # A room can stay alive after its drain without anything being wedged: a
    # second observer (the web app, another device) still holds it, and the
    # user's next frame re-observes the same pid. That must not pin the node in
    # paced mode, or an import during the edit re-creates 2026-09-14.
    test "a room kept alive after its drain paces one cycle, then pacing ends" do
      with_lru_config(drain_grace_ms: 100)

      a = live_room()
      CrdtRoomLru.touch("a-note", a, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("b-note", live_room(), @vault)

      CrdtRoomLru.sweep(1)
      Process.sleep(150)
      # `a` was asked but is still held, and the user types in it.
      CrdtRoomLru.touch("a-note", a, @vault)

      CrdtRoomLru.sweep(1)
      assert paced?(), "a stuck ask past its grace window paces this sweep"

      CrdtRoomLru.sweep(1)
      refute paced?(), "the same healthy room must not keep the node paced"
    end

    test "pacing ends once the stuck room exits" do
      with_lru_config(drain_grace_ms: 0)

      stuck = live_room()
      CrdtRoomLru.touch("s-note", stuck, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("t-note", live_room(), @vault)
      CrdtRoomLru.sweep(1)
      CrdtRoomLru.sweep(1)
      assert paced?()

      Process.exit(stuck, :kill)
      CrdtRoomLru.sweep(1)
      CrdtRoomLru.sweep(1)
      refute paced?()
    end

    # Matched on {note, pid}: a note whose room was replaced (the old drain
    # landed, a new room started) is not a stuck ask.
    test "a replacement room for an asked note is not counted as stuck" do
      with_lru_config(drain_grace_ms: 0)

      old = live_room()
      CrdtRoomLru.touch("r-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("q-note", live_room(), @vault)
      CrdtRoomLru.sweep(1)

      Process.exit(old, :kill)
      CrdtRoomLru.touch("r-note", live_room(), @vault)
      CrdtRoomLru.sweep(1)

      refute paced?()
    end

    # `Process.cancel_timer/1` cannot recall a message already delivered, so a
    # sweep message that lost its timer must be ignored rather than run.
    test "a prompt-sweep message from a cancelled timer is ignored" do
      with_lru_config(max_resident: 1)
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      :ets.insert(:crdt_room_lru, {"x-note", live_room(), @vault, 1})
      :ets.insert(:crdt_room_lru, {"y-note", live_room(), @vault, 2})

      send(CrdtRoomLru, {:over_cap_sweep, make_ref()})
      _ = :sys.get_state(CrdtRoomLru)

      refute_received {:crdt_room_drain, _}
    end

    defp paced?, do: :sys.get_state(CrdtRoomLru).paced

    # A 30s sweep interval alone let 9 new rooms/s pile ~270 over the cap
    # before anything looked. Crossing the cap schedules a prompt sweep.
    test "a new room past the cap triggers a sweep without waiting for the interval" do
      with_lru_config(max_resident: 1, over_cap_sweep_ms: 10)
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      old = live_room()
      CrdtRoomLru.touch("old-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", live_room(), @vault)

      assert_receive {:crdt_room_drain, ^old}, 1_000
    end

    test "re-touching a resident room does not schedule a sweep; a new room does" do
      with_lru_config(max_resident: 1, over_cap_sweep_ms: 60_000)

      # Two rooms are already over the cap of 1, but only a NEW room grows
      # residency; ordinary writes to existing rooms must stay a bare insert.
      a = live_room()
      :ets.insert(:crdt_room_lru, {"a-note", a, @vault, 1})
      :ets.insert(:crdt_room_lru, {"b-note", live_room(), @vault, 2})

      CrdtRoomLru.touch("a-note", a, @vault)
      assert over_cap_timer() == nil

      CrdtRoomLru.touch("c-note", live_room(), @vault)
      assert over_cap_timer() != nil
    end

    # `:sys.get_state/1` is a call, so it is served after any cast `touch/3`
    # already sent from this process.
    defp over_cap_timer, do: :sys.get_state(CrdtRoomLru).over_cap_timer

    defp with_lru_config(overrides) do
      prev = Application.get_env(:engram, CrdtRoomLru, [])
      Application.put_env(:engram, CrdtRoomLru, Keyword.merge(prev, overrides))
      on_exit(fn -> Application.put_env(:engram, CrdtRoomLru, prev) end)
    end

    defp drains_received(acc \\ 0) do
      receive do
        {:crdt_room_drain, _} -> drains_received(acc + 1)
      after
        200 -> acc
      end
    end

    # sweep/0 and the periodic timer both read max_resident() — every other test
    # passes the cap explicitly, so the configured reader (and its `|| @default`
    # nil-safety) never executed.
    test "sweep/0 falls back to the configured cap" do
      prev = Application.get_env(:engram, CrdtRoomLru, [])
      Application.put_env(:engram, CrdtRoomLru, Keyword.put(prev, :max_resident, 1))
      on_exit(fn -> Application.put_env(:engram, CrdtRoomLru, prev) end)

      old = live_room()
      new = live_room()

      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(@vault))

      CrdtRoomLru.touch("old-note", old, @vault)
      Process.sleep(5)
      CrdtRoomLru.touch("new-note", new, @vault)

      CrdtRoomLru.sweep()

      assert_receive {:crdt_room_drain, ^old}, 1_000
    end

    # The table is owned by this module's GenServer. A bare :ets call would
    # raise in the CALLER — which is a checkpoint timer linked to its room, so
    # the room would die by signal and skip its unbind checkpoint. A memory
    # backstop must never be able to cost a room its checkpoint.
    test "touch/forget degrade quietly while the table is missing" do
      :ok = GenServer.stop(CrdtRoomLru, :normal)

      assert CrdtRoomLru.touch("orphan", self(), @vault) == :ok
      assert CrdtRoomLru.forget("orphan") == :ok
      assert CrdtRoomLru.resident_count() == 0

      # Let the supervisor bring it back before the next test.
      wait_for_lru()
    end

    defp wait_for_lru(attempts \\ 100) do
      cond do
        attempts == 0 -> flunk("CrdtRoomLru never restarted")
        is_pid(Process.whereis(CrdtRoomLru)) and :ets.whereis(:crdt_room_lru) != :undefined -> :ok
        true -> Process.sleep(10) && wait_for_lru(attempts - 1)
      end
    end
  end
end
