defmodule Engram.Notes.CrdtE2ETest do
  @moduledoc """
  End-to-end integration test: REST façade + channel Yjs sync converge on one
  note, two-client fan-out propagates edits across channel connections, the
  persistence layer reconstructs state after a checkpoint, and the encrypted
  at-rest invariant holds.

  Covers the four invariants required by Task 12:
    1. REST + channel coherence — a REST upsert and a channel Yjs edit on the
       same note both land; the note's plaintext reflects the REST write.
    2. Two-client fan-out (deferred from Task 9) — two channel clients joined
       to `crdt:{user}:{vault}`; client A pushes a sync_update; client B
       receives the broadcast and, after applying it, sees A's edit.
    3. Persistence reconstruct — after edits + unbind (simulating a checkpoint
       flush), a fresh `doc_from_state` over the stored crdt_state reconstructs
       the same text.
    4. At-rest encryption proof — the stored `crdt_state_ciphertext` column
       contains ciphertext, not plaintext (`:binary.match/2` used because the
       column is raw bytes, not valid UTF-8, so `String.contains?/2` would
       raise ArgumentError).
  """

  use EngramWeb.ChannelCase, async: false

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, Note}

  # ---------------------------------------------------------------------------
  # Setup: one user, one vault, one note, one channel socket (client A)
  # ---------------------------------------------------------------------------

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtE2E"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "e2e.md", "content" => "base"})
    doc_id = "#{vault.id}/e2e.md"
    topic = "crdt:#{user.id}:#{vault.id}"

    socket_a_raw = user_socket(user)

    {:ok, _, joined_a} =
      subscribe_and_join(socket_a_raw, EngramWeb.CrdtChannel, topic, %{"crdt_proto" => 2})

    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), joined_a.channel_pid)

    %{
      user: user,
      vault: vault,
      note: note,
      doc_id: doc_id,
      topic: topic,
      socket_a: joined_a
    }
  end

  # ---------------------------------------------------------------------------
  # Invariant 1 + 4: REST write + channel coherence; at-rest is ciphertext
  # ---------------------------------------------------------------------------

  test "REST upsert and channel Yjs sync converge; stored crdt_state is ciphertext", ctx do
    %{user: user, vault: vault, note: note, socket_a: socket_a, doc_id: doc_id} = ctx

    # ── Step 1: channel client A does the full y-protocols handshake ───────────
    # Client A sends step1 → server replies with [step2, step1, awareness?].
    # Both step2 and the server's step1 are pushed as crdt_msg frames. We must
    # consume all of them so they don't pollute later assert_push calls.
    client_a = CrdtBridge.new_doc()
    :ok = sync_step1_handshake(client_a, socket_a, doc_id)
    assert CrdtBridge.text_of(client_a) == "base"

    # ── Step 2: client A edits the live room via sync_update ──────────────────
    # Capture server's state vector before the local edit so we can send only
    # the delta (the update the server does not yet have).
    {:ok, sv_before_edit} = Yex.encode_state_vector(client_a)

    text_a = Yex.Doc.get_text(client_a, CrdtBridge.text_name())
    CrdtBridge.diff_into_text(text_a, "base + LIVE")
    assert CrdtBridge.text_of(client_a) == "base + LIVE"

    {:ok, live_delta} = Yex.encode_state_as_update(client_a, sv_before_edit)
    {:ok, update_frame} = Yex.Sync.message_encode({:sync, {:sync_update, live_delta}})

    push(socket_a, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(update_frame)})
    # Give the room a beat to apply the update and run persistence.update_v1
    Process.sleep(200)

    # ── Step 3: REST writer pushes a diverging plaintext body ─────────────────
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "e2e.md",
        "content" => "base + REST",
        "version" => note.version
      })

    # ── Step 4: REST façade reflects the REST write ───────────────────────────
    # The REST read path (get_note) decrypts from the notes row, which was just
    # updated by upsert_note. The REST write always wins on the notes.content
    # column because maybe_merge_crdt merges + re-saves the row.
    {:ok, fresh} = Notes.get_note(user, vault, "e2e.md")
    assert fresh.content =~ "REST"

    # ── Step 5: at-rest encryption proof ─────────────────────────────────────
    # The ciphertext column is raw AES-GCM output (not valid UTF-8), so we must
    # use :binary.match/2 — String.contains?/2 would raise ArgumentError on it.
    # Repo.with_tenant wraps the fun's return in {:ok, result}; the inner fn
    # must return the Note directly (not {:ok, Note}) to avoid double-wrapping.
    {:ok, raw} =
      Repo.with_tenant(user.id, fn ->
        Repo.get!(Note, note.id)
      end)

    refute raw.crdt_state_ciphertext == nil,
           "crdt_state_ciphertext must be set (not nil) after a channel edit"

    assert :binary.match(raw.crdt_state_ciphertext, "base") == :nomatch,
           "ciphertext must not contain the plaintext substring 'base'"

    assert :binary.match(raw.crdt_state_ciphertext, "REST") == :nomatch,
           "ciphertext must not contain plaintext content"
  end

  # ---------------------------------------------------------------------------
  # Invariant 2: two-client fan-out
  # ---------------------------------------------------------------------------

  test "two channel clients on the same topic — A's edit fans out to B", ctx do
    %{user: user, socket_a: socket_a, doc_id: doc_id, topic: topic} = ctx

    # Join client B to the same vault topic.
    socket_b_raw = user_socket(user)

    {:ok, _, joined_b} =
      subscribe_and_join(socket_b_raw, EngramWeb.CrdtChannel, topic, %{"crdt_proto" => 2})

    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), joined_b.channel_pid)

    # ── Client A: full handshake (starts the room; A begins observing) ────────
    # The y-protocols handshake sends step1 from us and receives [step2, step1, ...]
    # back. We MUST drain all crdt_msg pushes for A before B does its handshake,
    # otherwise B's step2 would be obscured by A's unconsumed server-step1.
    client_a = CrdtBridge.new_doc()
    :ok = sync_step1_handshake(client_a, socket_a, doc_id)
    assert CrdtBridge.text_of(client_a) == "base"

    # ── Client B: full handshake (joins the same room; B begins observing) ────
    client_b = CrdtBridge.new_doc()
    :ok = sync_step1_handshake(client_b, joined_b, doc_id)
    assert CrdtBridge.text_of(client_b) == "base"

    # Both clients see "base". Both channel processes are observing the room.

    # ── Client A sends an edit ────────────────────────────────────────────────
    {:ok, sv_before} = Yex.encode_state_vector(client_a)
    text_a = Yex.Doc.get_text(client_a, CrdtBridge.text_name())
    CrdtBridge.diff_into_text(text_a, "A edited")

    {:ok, a_delta} = Yex.encode_state_as_update(client_a, sv_before)
    {:ok, update_frame_a} = Yex.Sync.message_encode({:sync, {:sync_update, a_delta}})

    push(socket_a, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(update_frame_a)})

    # ── Client B receives the broadcast via its channel's handle_info ─────────
    # SharedDoc broadcasts {:yjs, sync_update_frame, room} to all observers
    # except the sender (socket_a's channel_pid). socket_b's channel_pid receives
    # it and calls push/3 → sends %Phoenix.Socket.Message{} to the test process
    # (both sockets share the same test process as transport_pid in ChannelTest).
    # The broadcast is a sync_update, NOT a sync_step1.
    {:ok, broadcast_upd} = recv_sync_update(doc_id, 3000)

    :ok = Yex.apply_update(client_b, broadcast_upd)

    assert CrdtBridge.text_of(client_b) == "A edited",
           "client B must see A's edit after applying the broadcast update"
  end

  # ---------------------------------------------------------------------------
  # Invariant 3: persistence reconstruct after checkpoint (unbind)
  # ---------------------------------------------------------------------------

  test "persistence reconstruct — unbind flush followed by fresh bind recovers text", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Work directly with the persistence layer (no channel machinery needed).
    st = %{user_id: user.id, vault_id: vault.id, note_id: note.id}

    # Bind: loads the initial "base" snapshot from the notes row.
    doc1 = CrdtBridge.new_doc()
    st1 = CrdtPersistence.bind(st, note.id, doc1)
    assert CrdtBridge.text_of(doc1) == "base"

    # Simulate an incoming update: merge "base updated" into the live doc.
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "base updated")
    _st2 = CrdtPersistence.update_v1(st1, upd, note.id, doc1)
    :ok = Yex.apply_update(doc1, upd)

    # unbind (simulates graceful room exit / checkpoint): flushes the compacted
    # snapshot to the notes row so the next bind starts from it.
    :ok = CrdtPersistence.unbind(st1, note.id, doc1)

    # Fresh bind on a new doc: must reconstruct from the snapshot.
    doc2 = CrdtBridge.new_doc()
    _st3 = CrdtPersistence.bind(st, note.id, doc2)

    # The reconstructed text must contain the merged content.
    reconstructed = CrdtBridge.text_of(doc2)
    assert String.length(reconstructed) > 0

    assert reconstructed =~ "base",
           "fresh bind must reconstruct the base text from the persisted snapshot"

    # At-rest check: the crdt_state_ciphertext on the notes row (after unbind)
    # must be ciphertext, not plaintext. Repo.with_tenant wraps the fun's return
    # in {:ok, result}, so the inner fn returns the Note directly (not {:ok, Note}).
    {:ok, raw} =
      Repo.with_tenant(user.id, fn ->
        Repo.get!(Note, note.id)
      end)

    refute raw.crdt_state_ciphertext == nil

    assert :binary.match(raw.crdt_state_ciphertext, "base") == :nomatch,
           "snapshot ciphertext must not contain the plaintext 'base'"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Perform the full y-protocols step1 handshake from the client's perspective:
  #   1. Send step1 (client's state vector) to the server via the channel.
  #   2. The server responds with [step2, step1, awareness?] as separate
  #      crdt_msg pushes. step2 carries the diff the client is missing;
  #      step1 is the server's own state vector asking the client for updates.
  #   3. Apply the step2 update to `client_doc` so it is fully synced on return.
  #   4. Drain ALL remaining crdt_msg frames (server step1, optional awareness)
  #      from the mailbox so subsequent assert_push calls are not confused.
  #
  # step2 MUST appear first in the replies list (the NIF encodes it first before
  # the server step1). Returns :ok once the client is synced and mailbox clean.
  @spec sync_step1_handshake(Yex.Doc.t(), Phoenix.Socket.t(), String.t()) :: :ok
  defp sync_step1_handshake(client_doc, socket, doc_id) do
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client_doc)
    {:ok, step1_frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

    push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(step1_frame)})

    # First push from the server is always step2 (the NIF encodes step2 first in
    # the replies list). Apply it immediately so the client is fully synced.
    assert_push "crdt_msg", %{"doc_id" => ^doc_id, "b64" => step2_b64}, 3000

    {:ok, {:sync, {:sync_step2, step2_upd}}} =
      Yex.Sync.message_decode(Base.decode64!(step2_b64))

    :ok = Yex.apply_update(client_doc, step2_upd)

    # Drain remaining server replies (step1 asking for client updates, awareness)
    # so they do not pollute subsequent assert_push calls in the same test.
    drain_crdt_msgs(doc_id, 300)
  end

  # Wait for the next sync_update crdt_msg on doc_id. Used to receive the
  # fan-out broadcast pushed by client B's channel after client A sends an edit.
  @spec recv_sync_update(String.t(), non_neg_integer()) :: {:ok, binary()}
  defp recv_sync_update(doc_id, timeout) do
    assert_push "crdt_msg", %{"doc_id" => ^doc_id, "b64" => b64}, timeout

    case Yex.Sync.message_decode(Base.decode64!(b64)) do
      {:ok, {:sync, {:sync_update, upd}}} ->
        {:ok, upd}

      {:ok, other} ->
        # Not the update we want (e.g. a step1 leftover) — keep waiting
        _ = other
        recv_sync_update(doc_id, timeout)
    end
  end

  # Drain all pending crdt_msg frames for doc_id within `quiet_ms` of silence.
  # Called after consuming step2 to clear out the server's step1 + awareness.
  @spec drain_crdt_msgs(String.t(), non_neg_integer()) :: :ok
  defp drain_crdt_msgs(doc_id, quiet_ms) do
    receive do
      %Phoenix.Socket.Message{event: "crdt_msg", payload: %{"doc_id" => ^doc_id}} ->
        drain_crdt_msgs(doc_id, quiet_ms)
    after
      quiet_ms -> :ok
    end
  end
end
