defmodule Engram.Notes.CrdtPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` impl, posture C.

  * `bind/3`  — on room start, decrypt the note's `crdt_state` snapshot and
    apply it, then replay the encrypted tail-log. The room's doc is then the
    authoritative merge of snapshot + all updates since.
  * `update_v1/4` — append each incoming update to the encrypted tail-log
    (cheap, frequent). The full snapshot is rewritten on debounced checkpoints
    (`Engram.Notes.CrdtCheckpoint`), NOT here — keeps the hot path O(append).
  * `unbind/3` — on graceful room exit (last observer disconnect with
    `auto_exit: true`), run a full synchronous checkpoint: materializes
    content/content_hash/seq into the notes row and enqueues a debounced
    embed. When text is unchanged the checkpoint degrades to a
    snapshot-compaction write with no version/seq churn.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  import Ecto.Query
  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Logger.Metadata
  alias Engram.Sync.Broadcast

  alias Engram.Notes.{
    CheckpointGate,
    CrdtBridge,
    CrdtCheckpointTimer,
    CrdtTransport,
    CrdtUpdateLog,
    Enqueue,
    Note
  }

  require Logger

  # `bind/3`'s return value becomes the `persistence_state` threaded to every
  # subsequent `update_v1/4` and `unbind/3` call. We resolve the user ONCE here
  # and cache it in the state so the per-update hot path does NOT do an
  # `Accounts.get_user!` DB round-trip on every keystroke.
  @impl true
  def bind(%{user_id: user_id, note_id: note_id} = state, _doc_name, doc) do
    # bind/3 runs INSIDE the room (SharedDoc.init). Trapping exits here makes
    # gen_server intercept the supervisor's :shutdown on deploys and run
    # terminate/2 → unbind → full checkpoint, instead of dying unflushed.
    # Guarded on :"$initial_call" (set by proc_lib for GenServers) so a direct
    # bind/3 call from a bare test process does not leak trap_exit=true into
    # the test, where it would swallow linked-process crashes.
    if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)

    user = Accounts.get_user!(user_id)

    _ =
      Repo.with_tenant(user_id, fn ->
        case Repo.get(Note, note_id) do
          %Note{} = note ->
            from_snapshot? =
              case Crypto.decrypt_crdt_state(note, user) do
                {:ok, snapshot} when is_binary(snapshot) ->
                  :ok = Yex.apply_update(doc, snapshot)
                  true

                _ ->
                  false
              end

            tail_count = replay_tail(doc, user, note_id)

            # Fresh room: no snapshot AND no tail-log updates means this note has
            # never been CRDT-edited, so the only source of truth is the plaintext
            # `notes.content`. Seed the doc from it so a device that has never
            # opened the note (discovery via the crdt_doc_ready announce or a
            # /changes pull) still receives the body over the y-protocols
            # handshake. The client's `seedOnce` guard (skips when an LCA exists)
            # prevents a double-seed once the server is authoritative.
            if not from_snapshot? and tail_count == 0 do
              seed_from_content(doc, note, user)
            end

            :ok = CrdtBridge.normalize_doc(doc)

          nil ->
            :ok
        end
      end)

    # Cache the resolved user in the threaded state for update_v1/4 and unbind/3.
    Map.put(state, :user, user)
  end

  # Uses the user cached by bind/3 when present (the live room path); falls back
  # to a lazy fetch when called with a bare state map (direct unit-test calls).
  @impl true
  def update_v1(
        %{user_id: user_id, vault_id: vault_id, note_id: note_id} = state,
        update,
        _name,
        doc
      ) do
    user = state[:user] || Accounts.get_user!(user_id)

    case Crypto.encrypt_crdt_state(update, user, note_id) do
      {:ok, {ct, nonce}} ->
        Repo.with_tenant(user_id, fn ->
          %CrdtUpdateLog{}
          |> CrdtUpdateLog.changeset(%{
            note_id: note_id,
            user_id: user_id,
            vault_id: vault_id,
            update_ciphertext: ct,
            update_nonce: nonce
          })
          |> Repo.insert!()

          # Invalidate the cached head in the SAME txn as the tail append: this
          # update advanced the doc, so any stored crdt_head is now stale.
          # vault_heads self-heals the NULL by rebuilding once (snapshot + full
          # tail = authoritative), so we never trust an off-by-one head. Guard on
          # not-nil so an already-invalidated hot note skips the write. Sets ONLY
          # crdt_head — no updated_at/version/seq churn (checkpoint owns those).
          from(n in Note,
            where: n.id == ^note_id and n.kind == "note" and not is_nil(n.crdt_head)
          )
          |> Repo.update_all(set: [crdt_head: nil])
        end)

        # Fan out the update to every device on this vault over the single
        # per-vault sync channel (Relay's `document.updated` model). This is
        # what lets an IDLE note (one the client never STEP1-enrolled) converge
        # without opening its own CRDT room: the client applies these pushed
        # bytes straight to the note's Y.Doc. Fires on EVERY update source
        # (channel, REST /updates, deliver-out) because they all funnel here.
        # base64 because the JSON serializer can't carry raw binary; `head` lets
        # the client advance its per-note watermark without a REST round-trip.
        # Self-echo is harmless: the client applies with REMOTE_ORIGIN (no
        # re-broadcast) and Yjs re-apply is a no-op.
        Broadcast.emit(
          "sync:#{user_id}:#{vault_id}",
          "note_yjs_update",
          %{
            "note_id" => note_id,
            "b64" => Base.encode64(update),
            "head" => CrdtTransport.head_marker(doc)
          }
        )

      {:error, reason} ->
        Logger.error(
          "crdt_update_log encrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
          Metadata.with_category(:error, :sync, note_id: note_id)
        )
    end

    # Signal the checkpoint timer so it can debounce a snapshot flush.
    # update_v1 is called inside the room GenServer process; the timer pid
    # was stored there by CrdtDoc.start_link via Process.put(:crdt_timer_pid).
    case Process.get(:crdt_timer_pid) do
      pid when is_pid(pid) -> CrdtCheckpointTimer.notify_activity(pid)
      _ -> :ok
    end

    state
  end

  # Runs on graceful room terminate (SharedDoc `auto_exit: true`). Materializes
  # content/content_hash/seq into the notes row and enqueues a debounced embed.
  # When text is unchanged, checkpoint degrades to a snapshot-compaction write
  # with no version/seq churn (the content_hash no-op guard).
  #
  # Concurrency-bounded (2026-07-09 pool-exhaustion fix): a socket drop with
  # `auto_exit: true` terminates ALL of that client's rooms at once, so up to
  # N synchronous checkpoints would fight the 10-connection pool and time out
  # (`DBConnection.ConnectionError`). CheckpointGate caps inline checkpoints;
  # under the cap we checkpoint synchronously as before (preserving
  # materialization timing for the common single-note-close case), and beyond
  # it we overflow to the durable, bounded `crdt_checkpoint` Oban queue so the
  # storm drains without exhausting the pool. Loss-free either way: the tail-WAL
  # is pruned only on a successful checkpoint. Any raise inside checkpoint is
  # caught and logged there, so unbind always returns :ok.
  @impl true
  def unbind(%{user_id: user_id, vault_id: vault_id, note_id: note_id}, _doc_name, doc) do
    _ =
      if CheckpointGate.acquire() do
        try do
          Engram.Notes.CrdtCheckpoint.checkpoint(user_id, vault_id, note_id, doc)
        after
          CheckpointGate.release()
        end
      else
        Enqueue.enqueue(
          Engram.Workers.CheckpointNote.new(%{
            user_id: user_id,
            vault_id: vault_id,
            note_id: note_id
          }),
          "crdt_checkpoint"
        )
      end

    :ok
  end

  # Replays the encrypted tail-log onto `doc` and returns the number of rows
  # found (whether or not each decrypted) so bind/3 can tell a fresh room (0
  # rows) from one that already carries CRDT history.
  #
  # Public so `maybe_merge_crdt/4` in `Engram.Notes` can reuse this function
  # when building the REST merge base: snapshot + tail ≡ bind/3's recipe.
  # Must be called inside the caller's `Repo.with_tenant` transaction — it
  # queries `CrdtUpdateLog` which is tenant-scoped by RLS.
  @doc false
  def replay_tail(doc, user, note_id) do
    rows =
      CrdtUpdateLog
      |> where([l], l.note_id == ^note_id)
      |> order_by([l], asc: l.inserted_at)
      |> Repo.all()

    Enum.each(rows, fn row ->
      shaped = %Note{
        id: note_id,
        dek_version: Crypto.row_version_aad_bound(),
        crdt_state_ciphertext: row.update_ciphertext,
        crdt_state_nonce: row.update_nonce
      }

      case Crypto.decrypt_crdt_state(shaped, user) do
        {:ok, upd} when is_binary(upd) ->
          Yex.apply_update(doc, upd)

        {:error, reason} ->
          Logger.warning(
            "crdt replay_tail decrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
            Metadata.with_category(:warning, :sync, note_id: note_id, reason: inspect(reason))
          )

        unexpected ->
          Logger.warning(
            "crdt replay_tail unexpected decrypt result note_id=#{note_id} result=#{inspect(unexpected)}",
            Metadata.with_category(:warning, :sync,
              note_id: note_id,
              reason: "unexpected_shape"
            )
          )
      end
    end)

    length(rows)
  end

  # Seeds a fresh doc from the note's plaintext content via the frontmatter
  # codec. Used only when the note has no CRDT state yet (see bind/3) so
  # discovery delivers the body. Frontmatter is split into Y.Map("frontmatter")
  # + Y.Array("frontmatter_order") and only the body lands in the body Y.Text,
  # ensuring concurrent frontmatter edits engage the LWW per-key path.
  # maybe_decrypt_note_fields/2 also UTF-8-scrubs the content, keeping the Yjs
  # text JSON-safe. A nil/empty body seeds nothing (a blank note stays blank).
  defp seed_from_content(doc, %Note{} = note, user) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, %Note{content: content}} when is_binary(content) and content != "" ->
        :ok = CrdtBridge.ingest_plaintext(doc, content)

      _ ->
        :ok
    end
  end
end
