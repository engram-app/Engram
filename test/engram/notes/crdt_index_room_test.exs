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
    {:ok, vault} = Vaults.create_vault(user, %{name: "IndexRoomTest"})
    {:ok, other} = Vaults.create_vault(user, %{name: "IndexRoomTestOther"})

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

  describe "inertness" do
    # The index room has NO persistence until #1151, so a drain would exit it
    # and take the whole index with it. `terminate/2` -> unbind is exactly what
    # makes draining a NOTE room lossless, and the index room has no such
    # thing yet. Enabling #1152 here before #1151 lands is silent index loss.
    test "the room runs NO checkpoint timer, so it cannot drain itself away", ctx do
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

      assert timers == [],
             "the index room must not drain until #1151 gives it a checkpoint — " <>
               "draining it now would exit the room and take the whole index with it"
    end

    test "a crashed room is not resurrected observer-less" do
      spec = CrdtIndexDoc.child_spec(vault_id: "v1", user_id: "u1")

      assert spec.restart == :temporary
    end
  end

  # A note room gets 15 s because a blown deadline costs it NOTHING — its tail
  # log replays. This room has no tail log, so a blown deadline loses every
  # index write since the last exit. It shipped on the OTP default of 5 s: the
  # risk ordering exactly inverted. One assertion, because the default is
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
           "the room WITHOUT a tail log must not get less flush time than the one with"

    assert spec.shutdown > 5_000, "the OTP default brutal-kills a ~2 MB encrypt + write"
  end
end
