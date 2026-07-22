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

            applied = replay_tail(doc, user, note_id)

            # Fresh room: no snapshot AND no tail-log updates applied means this
            # note has never been CRDT-edited, so the only source of truth is the
            # plaintext `notes.content`. Seed the doc from it so a device that has
            # never opened the note (discovery via the crdt_doc_ready announce or a
            # /changes pull) still receives the body over the y-protocols
            # handshake. The client's `seedOnce` guard (skips when an LCA exists)
            # prevents a double-seed once the server is authoritative.
            if not from_snapshot? and applied == [] do
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
        {:ok, seq} =
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
            #
            # The note's current vault-global change seq (Vaults.next_seq!-
            # assigned at the last write/checkpoint, the same field
            # `list_changes_by_seq` orders by), carried on the fan-out payload
            # below for gap-heal (spec §3 Phase D2), rides this SAME update_all
            # via a `select` on the query (update_all/delete_all have no
            # `:returning` option — Ecto only returns a second element when the
            # query itself carries a `select`) — this is the hot per-delta path
            # (moduledoc: "cheap, frequent... O(append)", prior pool-exhaustion
            # incident history), so a second unconditional Repo.get here would
            # double the query cost of every keystroke. The guard skips rows
            # whose crdt_head is already nil, so `rows` is empty in that case
            # and we fall back to a select-only read. KNOWN COST: crdt_head
            # starts nil and is only repopulated by another device's
            # head-read, so a SOLO typing burst takes the fallback on every
            # delta — a seq-only point-SELECT inside the already-open
            # transaction (NOT a full Note load — the Note row carries
            # crdt_state_ciphertext, the encrypted CRDT snapshot, KBs-MBs,
            # which a per-keystroke fallback must not drag across the
            # connection). Accepted: seq is heal-trigger-only (staleness
            # fine), and avoiding the read entirely would need per-room seq
            # caching or a no-op UPDATE (MVCC/WAL churn), both worse than a
            # select-only read.
            {_count, rows} =
              from(n in Note,
                where: n.id == ^note_id and n.kind == "note" and not is_nil(n.crdt_head),
                select: n.seq
              )
              |> Repo.update_all(set: [crdt_head: nil])

            case rows do
              [seq | _] ->
                seq

              [] ->
                Repo.one(from(n in Note, where: n.id == ^note_id, select: n.seq))
            end
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
        #
        # NOTE — `b64` here is the DELTA (this single update), paired with the
        # FULL post-apply `head`. `CrdtDeliver.fanout_idle` sends FULL state under
        # the same contract. A device behind the delta's causal deps (it never
        # STEP1-enrolled and missed an earlier update) PENDS the delta in Yjs, so
        # it does NOT actually reach `head`. The client MUST NOT blind-trust `head`
        # in that case: `applyPushedNoteUpdate` checks `hasPendingGap` post-apply
        # and, on a gap, pulls the full delta from its real state vector and
        # advances the watermark only to the head it truly reached (plugin
        # `e2304ed`). Without that client guard, the cheap cold-reconcile hash gate
        # would skip a silently-partial note.
        # GUARANTEE BOUNDARY (review 2026-07-22): this seq does not advance per
        # socket delta (checkpoint owns it), so a same-note burst of live deltas
        # shares ONE seq — the plugin's behind-detector cannot see a loss WITHIN
        # such a burst; those heal via checkpoint/announce instead. Seq gap-heal
        # covers seq-BUMPING edits (REST/MCP/checkpoint-driven). And a nil seq
        # (row deleted concurrently, the Repo.get fallback) is no signal at all:
        # omit the key rather than ship "seq" => nil to the behind-detector.
        payload = %{
          "note_id" => note_id,
          "b64" => Base.encode64(update),
          "head" => CrdtTransport.head_marker(doc)
        }

        payload = if is_integer(seq), do: Map.put(payload, "seq", seq), else: payload

        Engram.Notes.FanoutPacer.emit(
          "sync:#{user_id}:#{vault_id}",
          "note_yjs_update",
          payload,
          note_id
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

  # Replays the encrypted tail-log onto `doc` and returns the ids of the rows
  # that were ACTUALLY applied (decrypted successfully), in insertion order. A
  # caller that persists `doc` can then prune EXACTLY those rows — never a row
  # it did not fold in (a later concurrent append) and never a row that failed
  # to decrypt (which stays in the log for a future successful replay). `[]`
  # means nothing applied, which bind/3 reads as "fresh room".
  #
  # Returning applied ids (not a count) is the #285 fix substrate: an
  # `inserted_at`/id RANGE watermark can tie or reorder within a clock tick and
  # prune an unfolded row; an exact-id prune cannot.
  #
  # Public so `maybe_merge_crdt/4` in `Engram.Notes` can reuse this function
  # when building the REST merge base: snapshot + tail ≡ bind/3's recipe.
  # Must be called inside the caller's `Repo.with_tenant` transaction — it
  # queries `CrdtUpdateLog` which is tenant-scoped by RLS.
  @doc false
  @spec replay_tail(Yex.Doc.t(), map(), String.t()) :: [Ecto.UUID.t()]
  def replay_tail(doc, user, note_id) do
    rows =
      CrdtUpdateLog
      |> where([l], l.note_id == ^note_id)
      |> order_by([l], asc: l.inserted_at)
      |> Repo.all()

    rows
    |> Enum.reduce([], fn row, applied ->
      shaped = %Note{
        id: note_id,
        dek_version: Crypto.row_version_aad_bound(),
        crdt_state_ciphertext: row.update_ciphertext,
        crdt_state_nonce: row.update_nonce
      }

      case Crypto.decrypt_crdt_state(shaped, user) do
        {:ok, upd} when is_binary(upd) ->
          _ = Yex.apply_update(doc, upd)
          [row.id | applied]

        {:error, reason} ->
          Logger.warning(
            "crdt replay_tail decrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
            Metadata.with_category(:warning, :sync, note_id: note_id, reason: inspect(reason))
          )

          applied

        unexpected ->
          Logger.warning(
            "crdt replay_tail unexpected decrypt result note_id=#{note_id} result=#{inspect(unexpected)}",
            Metadata.with_category(:warning, :sync,
              note_id: note_id,
              reason: "unexpected_shape"
            )
          )

          applied
      end
    end)
    |> Enum.reverse()
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
