defmodule Engram.Notes.CrdtIndexRoomTest do
  @moduledoc """
  index-crdt 1 (#1150): the per-vault index room, under the #167 p0.

  Today identity lives in three places that have to agree — `NoteIdMap` in the
  client, the REST manifest, and the seq cursor — and every drift incident in
  `docs/context/relay-pattern-audit.md` traces to that split. Relay has no such
  class because identity converges through the SAME channel as content, as a
  `Y.Map` inside a synced doc. This room is the substrate for doing the same.

  Scope here is deliberately INERT: the room exists, syncs, and can be observed.
  Nothing writes to it and nothing depends on it. Checkpoint/projection is
  #1151, client adoption is Engram-obsidian#362/#363.

  ## Why this room must NOT opt into the #1152 drain yet

  A note room is safe to drain because `terminate/2` → `CrdtPersistence.unbind/3`
  checkpoints it first. The index room has NO persistence until #1151, so a
  drain would exit it and evaporate the whole index. `idle_exit_ms` stays unset
  here, and the test below pins that — the two features combine badly if wired
  naively, and nothing else would catch it.
  """
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "IndexRoomTest", Ecto.UUID.generate())
    {:ok, other, _} = Vaults.register_vault(user, "IndexRoomTestOther", Ecto.UUID.generate())

    %{user: user, vault: vault, other_vault: other}
  end

  describe "registry" do
    test "a vault's index room is a cluster-wide singleton", ctx do
      {:ok, room} = CrdtIndexRegistry.ensure_started(ctx.user.id, ctx.vault.id)
      {:ok, again} = CrdtIndexRegistry.ensure_started(ctx.user.id, ctx.vault.id)

      assert is_pid(room)
      assert again == room
    end

    test "each vault gets its OWN room — one vault's index can never serve another", ctx do
      {:ok, a} = CrdtIndexRegistry.ensure_started(ctx.user.id, ctx.vault.id)
      {:ok, b} = CrdtIndexRegistry.ensure_started(ctx.user.id, ctx.other_vault.id)

      refute a == b
    end

    test "lookup/1 does not spin a room for a vault nobody is observing", ctx do
      assert CrdtIndexRegistry.lookup(ctx.vault.id) == nil

      {:ok, room} = CrdtIndexRegistry.ensure_started(ctx.user.id, ctx.vault.id)
      assert CrdtIndexRegistry.lookup(ctx.vault.id) == room
    end
  end

  describe "sync" do
    test "two clients converge on the index map through syncStep1/2", ctx do
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      # Client A writes an index entry and pushes it as a normal Yjs update.
      a = Engram.Notes.CrdtBridge.new_doc()

      a
      |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
      |> Yex.Map.set("Notes/a.md", %{"note_id" => "n-1", "type" => "md", "hash" => "h1"})

      {:ok, update} = Yex.encode_state_as_update(a)
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
      :ok = SharedDoc.send_yjs_message(room, frame)

      # Client B handshakes from empty and must receive A's entry.
      b = Engram.Notes.CrdtBridge.new_doc()
      {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(b)
      {:ok, step1} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      :ok = SharedDoc.send_yjs_message(room, step1)

      assert_receive {:yjs, reply, ^room}, 3_000
      {:ok, {:sync, {:sync_step2, diff}}} = Yex.Sync.message_decode(reply)
      :ok = Yex.apply_update(b, diff)

      entry = b |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch!("Notes/a.md")
      assert entry["note_id"] == "n-1"
    end

    test "the map survives an observer leaving and rejoining", ctx do
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      SharedDoc.update_doc(room, fn doc ->
        doc
        |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
        |> Yex.Map.set("Notes/keep.md", %{"note_id" => "n-keep"})
      end)

      # A second observer joins and the FIRST one leaves. Without the handover
      # the room would hit zero observers and auto_exit, taking the (memory-only,
      # until #1151) map with it — so this only passes if the room genuinely
      # outlives the churn rather than nothing having happened.
      me = self()

      holder =
        spawn_link(fn ->
          {:ok, ^room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
          send(me, :holding)
          receive do: (:release -> :ok)
        end)

      assert_receive :holding, 3_000
      :ok = SharedDoc.unobserve(room)

      assert Process.alive?(room), "the second observer must keep the room up"

      doc = SharedDoc.get_doc(room)
      map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
      assert Yex.Map.fetch!(map, "Notes/keep.md")["note_id"] == "n-keep"

      send(holder, :release)
    end
  end

  describe "room lifetime" do
    # INVERTED (#1152). This used to assert `timers == []` — that the room ran
    # no timer at all — because a drain with no `terminate/2` checkpoint behind
    # it would have exited the room and taken the whole index with it.
    #
    # Both prerequisites have since landed: #1151 gave the room a checkpoint on
    # unbind, and #1391 gave it a tail log so even an ungraceful death is
    # survivable. The room now runs a timer, and what has to be pinned is no
    # longer its absence but its SHAPE — an index-mode timer that never ticks a
    # checkpoint of its own.
    test "the room runs an INDEX-mode timer, which never checkpoints on a tick", ctx do
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      # Inspect what the room is actually LINKED to, not the opts this test
      # passed in — an assertion over its own input would pass no matter what
      # start_link/1 does. A CrdtCheckpointTimer links itself to its room, so
      # its absence here is the real "no drain" invariant.
      {:links, links} = Process.info(room, :links)

      timers =
        Enum.filter(links, fn pid ->
          is_pid(pid) and
            match?(
              {Engram.Notes.CrdtCheckpointTimer, :init, 1},
              Process.info(pid, :dictionary)
              |> elem(1)
              |> Keyword.get(:"$initial_call")
            )
        end)

      assert [timer] = timers,
             "the index room runs no checkpoint timer, so nothing can ever drain it " <>
               "and its residency stays session-length (#1152)"

      state = :sys.get_state(timer)

      # `:index`, not `:note`. A note-mode timer would tick `CrdtCheckpoint`
      # against this room — and an index checkpoint that does not come from
      # `unbind/3` cannot know which tail rows failed to replay, so it would
      # prune claims it never folded in (#1391).
      assert state.mode == :index
      assert state.room_key == ctx.vault.id

      # ON, not opt-in. `nil` is how the timer spells "drain disabled", so a
      # room that fell through to the note-room config fallback would go back to
      # session-length residency the moment that knob was unset — the measured
      # 7.91 MB/vault (#1149), shipped silently.
      assert is_integer(state.idle_exit_ms) and state.idle_exit_ms > 0,
             "the index room's drain must not depend on a flag being set"

      # A tick must be inert rather than merely unlikely. Drive one directly:
      # the note path would crash on a nil note.
      send(timer, :tick)
      Process.sleep(50)
      assert Process.alive?(timer)
    end

    test "a crashed room is not resurrected observer-less" do
      spec = CrdtIndexDoc.child_spec(vault_id: "v1", user_id: "u1")

      assert spec.restart == :temporary
    end
  end

  # Both rooms now have a tail log (#1391), so a blown deadline no longer loses
  # writes on either — it costs the FOLD. The checkpoint never runs, nothing is
  # pruned, and the tail grows across restarts. This room still gets the longer
  # budget because its flush is a single ~2 MB encode + encrypt for the whole
  # vault, against a note's one document. It shipped on the OTP default of 5 s,
  # which brutal-kills that flush. One assertion, because the default is
  # invisible (there is no `shutdown:` key to read).
  test "the shutdown budget exceeds a note room's, because a blown deadline costs more here" do
    spec = CrdtIndexDoc.child_spec(vault_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate())

    note_spec =
      Engram.Notes.CrdtDoc.child_spec(
        note_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        vault_id: Ecto.UUID.generate()
      )

    assert spec.shutdown >= note_spec.shutdown,
           "the room with the whole-vault flush must not get less time than a single note's"

    assert spec.shutdown > 5_000, "the OTP default brutal-kills a ~2 MB encrypt + write"
  end
end
