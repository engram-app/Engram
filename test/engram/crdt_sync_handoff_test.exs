defmodule Engram.CrdtSyncHandoffTest do
  @moduledoc """
  A CRDT (web-editor) edit emits NO note_changed on the sync: topic — by
  design, the only delivery guarantee for a sync-topic-only device (the
  plugin) is the /api/sync/changes cursor feed. That handoff was never
  tested: a regression that kept CRDT persistence out of the seq feed made
  web edits silently invisible to Obsidian. This test pins both halves:
  the (documented) silence AND the feed delivery.

  Silence premise checked against #940 (fix/crdt-web-edit-delivery, already
  merged on this branch): the checkpoint's new discovery announce
  (`CrdtDeliver.announce_ready/4`) broadcasts `crdt_doc_ready` on the
  `crdt:<user_id>:<vault_id>` topic only
  (lib/engram/notes/crdt_deliver.ex:242-251 `defp announce/3`) — the
  `sync:` topic still emits no `note_changed` for a CRDT-origin write. #940
  does not change this test's silence premise.
  """
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtRegistry}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtSyncHandoffTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"})

    socket = user_socket(user)

    {:ok, _, joined} =
      subscribe_and_join(
        socket,
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), joined.channel_pid)

    %{socket: joined, user: user, vault: vault, note: note}
  end

  test "CRDT edit is silent on sync: topic but lands in the changes feed", %{
    socket: socket,
    user: user,
    vault: vault,
    note: note
  } do
    # 1. capture the current max cursor for the vault (changes-feed function)
    seq0 = Vaults.current_seq(user.id, vault.id)

    # 2. subscribe to "sync:#{user.id}:#{vault.id}"
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    # 3. drive a real Yjs update through the crdt channel (the update-crdt_msg
    #    pattern from crdt_channel_test.exs :301-344 — step1 handshake, apply
    #    the server's step2 state, mutate the client doc, ship the delta).
    client = CrdtBridge.new_doc()
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
    {:ok, step1_frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(step1_frame)})
    assert_push "crdt_msg", %{"b64" => b64_step2}, 3000
    {:ok, {:sync, {:sync_step2, upd}}} = Yex.Sync.message_decode(Base.decode64!(b64_step2))

    {:ok, server_sv_before} = Yex.encode_state_vector(client)
    :ok = Yex.apply_update(client, upd)
    assert CrdtBridge.text_of(client) == "base"

    text = Yex.Doc.get_text(client, CrdtBridge.text_name())
    Yex.Text.insert(text, 4, " EDITED VIA WEB")
    assert CrdtBridge.text_of(client) == "base EDITED VIA WEB"

    {:ok, delta} = Yex.encode_state_as_update(client, server_sv_before)
    {:ok, update_frame} = Yex.Sync.message_encode({:sync, {:sync_update, delta}})
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(update_frame)})

    {:ok, room_pid} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

    wait_until(fn ->
      CrdtBridge.text_of(SharedDoc.get_doc(room_pid)) == "base EDITED VIA WEB"
    end)

    # 4. force the checkpoint to persist NOW — bypass the debounce timer
    #    entirely by calling CrdtCheckpoint.checkpoint/4 directly with the
    #    room's live doc, exactly as crdt_checkpoint_test.exs does.
    room_doc = SharedDoc.get_doc(room_pid)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, room_doc)

    # 5. the CRDT write must NOT emit note_changed on the sync: topic — the
    #    documented design (only the seq changes feed carries this edit to a
    #    sync-topic-only device). If this ever starts receiving, the design
    #    changed (see #940 note above) and this test must be updated
    #    deliberately, not loosened.
    refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 200

    # 6. pull the changes feed from the step-1 cursor: the note must appear
    #    with the CRDT-updated (decrypted) content and a bumped seq.
    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, seq0)
    change = Enum.find(changes, &(&1.id == note.id))

    assert change, "checkpointed note missing from the seq changes feed"
    assert change.content == "base EDITED VIA WEB"
    assert change.seq > seq0
  end

  defp wait_until(condition, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 500

    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("wait_until: condition never became true within 500ms")
      else
        Process.sleep(10)
        wait_until(condition, deadline)
      end
    end
  end
end
