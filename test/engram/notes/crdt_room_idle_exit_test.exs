defmodule Engram.Notes.CrdtRoomIdleExitTest do
  @moduledoc """
  The room-lifetime model for engram-app/Engram#1152 (under the #167 p0 umbrella).

  A per-note room exits via `auto_exit`, which is purely last-observer-driven
  (`deps/y_ex/lib/protocols/shared_doc.ex:190,198`). That works for notes — a
  note is open briefly — but an INDEX room is observed for as long as any client
  is connected, so its lifetime becomes session-length and residency scales with
  concurrent connections instead of mutation rate. #1149 measured 7.91 MB
  resident per 10k-note vault, so that is two orders of magnitude off target.

  These tests pin the protocol that bounds it:

      idle timer fires
        -> broadcast {:crdt_room_drain, room} on the room's drain topic
          -> each observer evicts its cached pid, then unobserves
            -> the LAST unobserve trips the EXISTING auto_exit
              -> terminate/2 -> CrdtPersistence.unbind/3 -> checkpoint

  Nothing here stops the room directly, and that is the whole point. #1152 asks
  for "a timer that exits with observers still attached" — but a room killed out
  from under an attached observer silently eats the next `sync_update` frame:
  y_ex dispatches those as a `GenServer.cast`
  (`deps/y_ex/lib/server/doc_server_worker.ex:26`), and a cast to a dead pid
  returns `:ok` while dropping the edit. `crdt_channel.ex` already carries that
  warning at its room monitor. Draining observers first makes the exit fall out
  of the mechanism that already exists, with no window for a lost frame.
  """
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtDoc, CrdtRegistry}
  alias Yex.Sync.SharedDoc

  @idle_ms 150

  # The re-arm test has two conflicting timing requirements: each gap between
  # edits must stay RELIABLY under the idle window (or the room really is idle
  # and the drain correctly fires), while the TOTAL activity period must exceed
  # it (or a never-re-armed timer would not have fired either, and the test
  # discriminates nothing).
  #
  # The first version used a 2x ratio (75 ms gaps, 150 ms window) and failed
  # ~70% of the time under CPU contention: a loaded scheduler overshoots the
  # sleep, the room is genuinely idle past the window, and `idle?/2` fires
  # exactly as designed. That test was asserting the machine's timeliness, not
  # the code's behaviour. 6x gap-to-window, with a total that clears the window
  # three times over.
  @rearm_idle_ms 1_200
  @rearm_gap_ms 200
  @rearm_edits 10

  setup do
    # Park the checkpoint debounce far out of reach so the ONLY thing that can
    # materialize content in these tests is the unbind checkpoint on room exit.
    # Without this the eager 250ms flush would materialize anyway and the
    # "checkpoints on exit" assertion below would pass vacuously.
    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IdleExitTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})

    %{user: user, vault: vault, note: note}
  end

  # Start a room directly (not via CrdtRegistry.ensure_started/3, which owns no
  # opts pass-through yet) so a test can choose the idle window per room.
  defp start_room(%{user: user, vault: vault, note: note}, opts) do
    spec =
      {CrdtDoc, [note_id: note.id, user_id: user.id, vault_id: vault.id] ++ opts}

    {:ok, room} = DynamicSupervisor.start_child(Engram.Notes.CrdtDocSupervisor, spec)
    room
  end

  defp edit(room, text) do
    :ok =
      SharedDoc.update_doc(room, fn doc ->
        doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> CrdtBridge.diff_into_text(text)
      end)
  end

  describe "drain broadcast" do
    test "an idle room asks its observers to let go WITHOUT stopping itself", ctx do
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(ctx.vault.id))
      room = start_room(ctx, idle_exit_ms: @idle_ms)
      :ok = SharedDoc.observe(room)

      assert_receive {:crdt_room_drain, ^room}, 1_000

      # The room is STILL ALIVE with an observer attached. If this ever fails,
      # the implementation went back to killing the room directly and the
      # cast-into-a-corpse edit-loss window is open again.
      assert Process.alive?(room)
    end

    test "activity re-arms the window so an actively-edited room is never drained", ctx do
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(ctx.vault.id))
      room = start_room(ctx, idle_exit_ms: @rearm_idle_ms)
      :ok = SharedDoc.observe(room)

      # Sustained editing for ~2s against a 1.2s window: a timer armed once at
      # room start would have fired long before this loop ends.
      for n <- 1..@rearm_edits do
        edit(room, "typing #{n}")
        Process.sleep(@rearm_gap_ms)
      end

      # refute_RECEIVED, not refute_receive: check the mailbox as it stands
      # rather than waiting further, so the assertion adds no timing surface.
      refute_received {:crdt_room_drain, ^room}
      assert Process.alive?(room)
    end

    # 0 is TRUTHY in Elixir, so it survives the `||` config fallback. Without the
    # positive-integer guard it would arm at 0 ms and spin the drain broadcast in
    # a tight loop.
    test "a zero idle window is treated as disabled, not as drain-immediately", ctx do
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(ctx.vault.id))
      room = start_room(ctx, idle_exit_ms: 0)
      :ok = SharedDoc.observe(room)

      refute_receive {:crdt_room_drain, ^room}, 300
      assert Process.alive?(room)
    end

    test "the first drain is counted so ops can compare asks against releases", ctx do
      test_pid = self()
      handler = "req-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      room = start_room(ctx, idle_exit_ms: @idle_ms)
      :ok = SharedDoc.observe(room)

      assert_receive {:drain_telemetry, %{count: 1}, %{phase: :requested}}, 2_000
    end

    test "a room without idle_exit_ms never drains — note rooms are unchanged", ctx do
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(ctx.vault.id))
      room = start_room(ctx, [])
      :ok = SharedDoc.observe(room)

      refute_receive {:crdt_room_drain, ^room}, @idle_ms * 4
      assert Process.alive?(room)
    end
  end

  describe "exit + checkpoint" do
    test "the last unobserve trips auto_exit, and terminate checkpoints the edit", ctx do
      %{user: user, vault: vault, note: note} = ctx
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(vault.id))
      room = start_room(ctx, idle_exit_ms: @idle_ms)
      :ok = SharedDoc.observe(room)
      ref = Process.monitor(room)

      edit(room, "before AND A DRAINED EDIT")

      assert_receive {:crdt_room_drain, ^room}, 1_000

      # What a channel does on drain: let go. auto_exit does the rest.
      :ok = SharedDoc.unobserve(room)

      assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000

      {:ok, materialized} = Notes.get_note_by_id(user, vault, note.id)
      assert materialized.content =~ "A DRAINED EDIT"
    end

    test "the :global registration is released so the next edit gets a fresh room", ctx do
      %{user: user, vault: vault, note: note} = ctx
      Phoenix.PubSub.subscribe(Engram.PubSub, CrdtRegistry.drain_topic(vault.id))
      room = start_room(ctx, idle_exit_ms: @idle_ms)
      :ok = SharedDoc.observe(room)
      ref = Process.monitor(room)

      assert_receive {:crdt_room_drain, ^room}, 1_000
      :ok = SharedDoc.unobserve(room)
      assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000

      # Re-spin: same note, brand-new room process.
      {:ok, respun} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
      assert is_pid(respun)
      refute respun == room
    end
  end
end
