defmodule Engram.Notes.CrdtCheckpoint do
  @moduledoc """
  Flush a live CRDT room to durable state. Encodes the doc, encrypts the
  snapshot into `notes.crdt_state`, re-materializes the plaintext snapshot
  (content / content_hash / title / tags) so the REST + search façade stays
  current, bumps `seq`, prunes the consumed tail-log, and enqueues a debounced
  embed. Runs on a debounced timer (5s idle / 60s ceiling) — NEVER per update.

  ## Virtual field materialization

  `note.path`, `note.folder`, and `note.title` are VIRTUAL columns — a bare
  `Repo.get!` leaves them nil. Without materialization through
  `Crypto.maybe_decrypt_note_fields/2`, `extract_title` falls back to the note
  UUID, and `inject_phase_b_fields_pub` receives nil path/folder which corrupts
  path_hmac and folder_hmac, making the row unresolvable by path. We always
  decrypt the existing row FIRST, extract virtual fields, then re-derive title
  from the decrypted path before building the new changeset.
  """
  import Ecto.Query

  alias Engram.{Accounts, Crypto, Notes, Repo, Vaults}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtDeliver, CrdtUpdateLog, Enqueue, Helpers, Note}
  alias Engram.Workers.EmbedNote

  require Logger

  @doc """
  Checkpoint the live doc into the `notes` row. Encrypts the full Yjs v1
  state, prunes the tail-log, and — when the projected text actually changed —
  re-materializes plaintext columns, bumps version/seq, and enqueues a
  debounced embed. When the text is unchanged (hash match) it degrades to a
  snapshot-compaction write with NO version/seq churn, so calling it on every
  room exit is cheap.

  Options:
    * `:prune_ids` — the EXACT ids of the tail rows folded into `doc` (from
      `CrdtPersistence.replay_tail/3`). Prune deletes only these. Required for
      DETACHED-doc callers (`CheckpointNote`) whose `doc` reflects a fixed
      replay set, not the live tail: an id-range/watermark prune can tie within
      a clock tick and destroy a concurrent append (#285).
    * `:watermark` — a pre-captured `inserted_at` prune boundary for LIVE-room
      callers (timer / unbind), whose `doc` is the live NIF ref and so reflects
      every tail row up to now. When both are omitted, the watermark is captured
      here BEFORE the doc is encoded, so rows landing mid-encode survive the
      prune. `:prune_ids` takes precedence when present.

  Never called per-keystroke — driven by `CrdtCheckpointTimer` (debounced)
  and by `CrdtPersistence.unbind/3` on room exit. Never raises: any internal
  failure is logged and returns `:ok` (safe in the room's terminate path).
  """
  @spec checkpoint(String.t(), String.t(), String.t(), Yex.Doc.t(), keyword()) :: :ok
  def checkpoint(user_id, vault_id, note_id, %Yex.Doc{} = doc, opts \\ []) do
    # Deleted user/note are EXPECTED lifecycle states here (vault force-purge
    # deletes rows while rooms are still exiting) — skip quietly at :warning,
    # never raise. Raising turned every room tick during a purge into a
    # caught-but-logged error storm (Sentry + Loki, 2026-07-07 19:03, #954).
    case Accounts.get_user(user_id) do
      nil ->
        Logger.warning(
          "crdt checkpoint skipped — user deleted note_id=#{note_id}",
          Metadata.with_category(:warning, :sync, note_id: note_id)
        )

        :ok

      user ->
        do_checkpoint(user, user_id, vault_id, note_id, doc, opts)
    end
  end

  defp do_checkpoint(user, user_id, vault_id, note_id, doc, opts) do
    # Determine the prune boundary. `:prune_ids` (detached callers) is the exact
    # set of folded rows — safest. Otherwise fall back to the `inserted_at`
    # watermark path for live-room callers whose doc reflects the whole tail.
    prune =
      case Keyword.fetch(opts, :prune_ids) do
        {:ok, ids} when is_list(ids) ->
          {:ids, ids}

        :error ->
          # Capture the prune watermark BEFORE reading/encoding the doc. Any tail
          # row inserted while we encode is NOT necessarily in the snapshot, so it
          # must survive the prune (it replays on next bind — apply_update is
          # idempotent).
          case Keyword.fetch(opts, :watermark) do
            {:ok, wm} ->
              {:watermark, wm}

            :error ->
              # A capture failure degrades to nil: prune becomes a no-op, which is
              # the safe direction (rows are kept and replayed on next bind).
              case Repo.with_tenant(user_id, fn -> tail_watermark(note_id) end) do
                {:ok, wm} -> {:watermark, wm}
                _ -> {:watermark, nil}
              end
          end
      end

    # Phase 0 monotonicity (identity-as-CRDT): never materialize the live doc's
    # state directly. Encode it ONCE (read-only — the room's doc is never
    # mutated from here), then fold the row's STORED state into a scratch doc
    # and materialize the union. The stored state is the same lineage
    # deliver_out pushes, so the fold is idempotent; a room that missed a
    # deliver_out (decrypt blip, KMS outage) is BEHIND writes that committed
    # before any fence capture, and without the union its checkpoint would
    # overwrite content AND crdt_state with the stale doc — destroying the
    # REST/MCP write entirely (prod incident 2026-07-07: MCP appends erased).
    # With the union the persisted state only ever grows; deletions still win
    # (causally newer ops), and the version CAS below still guards the
    # mid-checkpoint race window.
    case encode(doc) do
      {:ok, live_state} ->
        # with_tenant wraps the fun's return in {:ok, _} (Ecto transaction). The
        # fun returns {prev_hash, path} on a write (prev_hash drives the
        # embed/deliver guard, path feeds the post-commit announce) or
        # {:abort, reason} when the stored state is unreadable — overwriting a
        # state we cannot prove we contain could destroy data, so we write
        # nothing (unreadable ≠ absent).
        {:ok, outcome} =
          Repo.with_tenant(user_id, fn ->
            # `note.path` / `note.folder` / `note.title` are VIRTUAL — a bare
            # Repo.get! leaves them nil. Materialize through the decrypt path so
            # they are populated BEFORE we re-derive title + re-HMAC path/folder.
            # Without this, extract_title falls back to the UUID and
            # inject_phase_b_fields_pub gets nil path/folder → corrupts
            # path_hmac/folder_hmac so the row stops resolving by path.
            case Repo.get(Note, note_id) do
              # Deleted note (vault force-purge race): quiet skip, see checkpoint/5.
              nil ->
                {:skip, :note_deleted}

              raw_note ->
                {:ok, note} = Crypto.maybe_decrypt_note_fields(raw_note, user)

                with {:ok, union_doc} <- union_with_row_state(note, live_state, user),
                     text = CrdtBridge.text_of(union_doc),
                     {:ok, raw_state} <- encode(union_doc),
                     {_flat_doc, state} <- maybe_flatten(union_doc, raw_state, note_id),
                     {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(state, user, note_id),
                     {:ok, key} <- Crypto.dek_content_hash_key(user) do
                  content_hash = Crypto.hmac_content_hash(key, text)
                  tags = Helpers.extract_tags(text)

                  checkpoint_write(note, vault_id, note_id, prune, opts, %{
                    text: text,
                    tags: tags,
                    content_hash: content_hash,
                    ct: ct,
                    nonce: nonce,
                    user: user
                  })
                else
                  err -> {:abort, err}
                end
            end
          end)

        case outcome do
          {prev_hash, new_hash, path} ->
            _ =
              if prev_hash != new_hash do
                _ = Enqueue.enqueue(EmbedNote.new_debounced(note_id), "embed_note")

                # Deliver-out gap: a web-editor edit lands ONLY via this checkpoint,
                # which (unlike REST/MCP writes) never announced. A client not
                # actively enrolled in the room — e.g. Obsidian — thus never
                # discovered the edit, live or on next pull. Announce so it opens a
                # room and pulls the just-persisted state. Announce-ONLY (not full
                # deliver_out): live observers already converged via real-time frame
                # relay, and the room-state push would `GenServer.call` self on the
                # unbind path (checkpoint runs inside the room process there).
                # `prev_hash != new_hash` fires only on a committed content change
                # (compaction and the #902 stale-abort both return equal hashes),
                # so idle compactions and aborted writes raise no spurious re-pull.
                CrdtDeliver.announce_ready(user_id, vault_id, path, note_id)
              end

            :ok

          {:skip, reason} ->
            Logger.warning(
              "crdt checkpoint skipped — #{inspect(reason)} note_id=#{note_id}",
              Metadata.with_category(:warning, :sync, note_id: note_id)
            )

            :ok

          {:abort, err} ->
            Logger.error(
              "crdt checkpoint aborted note_id=#{note_id} reason=#{inspect(err)}",
              Metadata.with_category(:error, :sync, note_id: note_id)
            )

            :ok
        end

      err ->
        Logger.error(
          "crdt checkpoint failed note_id=#{note_id} reason=#{inspect(err)}",
          Metadata.with_category(:error, :sync, note_id: note_id)
        )

        :ok
    end
  rescue
    err ->
      Logger.error(
        "crdt checkpoint raised note_id=#{note_id} error=#{Exception.format(:error, err, __STACKTRACE__)}",
        Metadata.with_category(:error, :sync, note_id: note_id)
      )

      :ok
  end

  # Folds the row's stored CRDT state with the live doc's encoded state into a
  # fresh scratch doc (Yjs union — idempotent, shared lineage). Absent stored
  # state (legacy/lazy row) degrades to the live state alone; an UNREADABLE
  # stored state is an error, never a degrade.
  defp union_with_row_state(%Note{crdt_state_ciphertext: nil}, live_state, _user),
    do: CrdtBridge.doc_from_state(live_state)

  defp union_with_row_state(%Note{} = note, live_state, user) do
    case Crypto.decrypt_crdt_state(note, user) do
      {:ok, row_state} when is_binary(row_state) ->
        with {:ok, union_doc} <- CrdtBridge.doc_from_state(row_state),
             :ok <- Yex.apply_update(union_doc, live_state) do
          {:ok, union_doc}
        end

      {:ok, nil} ->
        CrdtBridge.doc_from_state(live_state)

      {:error, reason} ->
        {:error, {:row_state_unreadable, reason}}
    end
  end

  # The two persistence branches (compaction vs. materialize), unchanged in
  # behavior except that they now persist the UNION doc's text/state. Runs
  # inside the caller's tenant txn; returns {prev_hash, new_hash, path} —
  # equal hashes mean "no content change committed" (compaction / stale abort),
  # which suppresses the caller's embed + announce.
  defp checkpoint_write(note, vault_id, note_id, prune, opts, m) do
    %{text: text, tags: tags, content_hash: content_hash, ct: ct, nonce: nonce, user: user} = m
    prev = note.content_hash

    if prev == content_hash do
      # Text unchanged: compact the snapshot + prune, but do NOT touch
      # version/seq/content — legacy /changes pullers must not see phantom edits.
      {1, _} =
        Repo.update_all(
          from(n in Note, where: n.id == ^note_id and n.kind == "note"),
          set: [
            crdt_state_ciphertext: ct,
            crdt_state_nonce: nonce,
            dek_version: Crypto.row_version_aad_bound()
          ]
        )

      prune_tail(note_id, prune)
      {prev, content_hash, note.path}
    else
      # Re-derive title from the note's decrypted (sanitized-at-write) path.
      title = Helpers.extract_title(text, note.path)

      merged = %{content: text, title: title, tags: tags, content_hash: content_hash}
      {:ok, encrypted} = Crypto.encrypt_note_fields(merged, user, note_id)

      phase_b =
        Notes.inject_phase_b_fields_pub(
          encrypted,
          user,
          note_id,
          note.path,
          note.folder,
          tags
        )
        |> Notes.inject_okf_fields_pub(user, note_id, text)
        |> Map.put(:crdt_state_ciphertext, ct)
        |> Map.put(:crdt_state_nonce, nonce)
        |> Map.put(:content_hash, content_hash)

      # #902 fence. When the caller captured the doc at a known row version,
      # persist only if the row is STILL at that version. A REST/MCP write
      # that committed after the snapshot bumped `version`, so the CAS matches
      # zero rows and we ABORT — never overwriting the newer committed content
      # with our stale encoding. `captured_version` nil (e.g. the unbind path)
      # keeps the prior unfenced behaviour. The field set is derived through
      # Note.changeset (identical casting to the previous Repo.update!) and
      # applied via a version-fenced update_all, mirroring the compaction branch.
      captured = Keyword.get(opts, :captured_version)
      fence_version = captured || note.version

      changeset =
        note
        |> Note.changeset(Map.put(phase_b, :version, fence_version + 1))
        |> Ecto.Changeset.put_change(:seq, Vaults.next_seq!(vault_id))

      base_query = from(n in Note, where: n.id == ^note_id and n.kind == "note")

      fenced_query =
        if captured, do: where(base_query, [n], n.version == ^captured), else: base_query

      # update_all does NOT auto-manage timestamps (Repo.update! does), and
      # `updated_at` is never cast into changeset.changes. Set it explicitly —
      # matching every sibling notes update_all — or the /api/notes/changes
      # timestamp feed (filters + orders on updated_at) silently drops the edit.
      set = changeset.changes |> Map.put(:updated_at, DateTime.utc_now()) |> Map.to_list()

      case Repo.update_all(fenced_query, set: set) do
        {1, _} ->
          prune_tail(note_id, prune)
          {prev, content_hash, note.path}

        {0, _} ->
          # The row advanced since our snapshot — a newer write is already
          # committed. Do NOT prune (its tail rows may be unmerged) and do NOT
          # revert. Return equal hashes so the caller enqueues no embed for a
          # write that did not happen; the next debounce tick re-captures the
          # now-merged doc and checkpoints that.
          Logger.info(
            "crdt checkpoint skipped stale write note_id=#{note_id} captured_version=#{fence_version}",
            Metadata.with_category(:info, :sync, note_id: note_id)
          )

          {content_hash, content_hash, note.path}
      end
    end
  end

  defp encode(doc) do
    case Yex.encode_state_as_update(doc) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  # When BOTH the byte-size AND the client-ID thresholds are crossed, replace
  # the live doc with a fresh single-client reset (text preserved). Returns a
  # {doc, state} tuple in both branches so the caller's `with` chain is uniform.
  defp maybe_flatten(%Yex.Doc{} = doc, state, note_id) do
    if CrdtBridge.should_flatten?(state, doc) do
      Logger.info(
        "crdt flatten note_id=#{note_id} state_bytes=#{byte_size(state)} clients=#{CrdtBridge.client_count(doc)}",
        Metadata.with_category(:info, :sync, note_id: note_id)
      )

      case CrdtBridge.flatten(doc) do
        {:ok, %{doc: flat_doc, state: flat_state}} -> {flat_doc, flat_state}
        {:error, _} -> {doc, state}
      end
    else
      {doc, state}
    end
  end

  @doc """
  Read the current `notes.version` for a note (tenant-scoped), or nil on any
  failure. Captured by `CrdtCheckpointTimer` BEFORE it snapshots the live doc so
  the value fences the subsequent checkpoint write (`:captured_version`).

  Capturing version before the snapshot closes the dominant snapshot-then-commit
  gap: a commit landing after the read bumps the version, so the CAS aborts. It
  does NOT make a revert impossible — `version` bumps at REST commit while the
  live room doc only converges later at `CrdtDeliver.deliver_out`, so a commit
  inside that narrow commit→deliver window can still be captured-then-overwritten.
  That residual self-heals: deliver_out applies the merged state, which fires
  `update_v1` → a follow-up tick re-checkpoints the merged content.

  Returns nil on read failure, which degrades to an UNfenced write (prior
  behaviour). This is deliberate: nil is indistinguishable from the unbind
  path's absent `captured_version` (which must stay unfenced to persist on room
  exit), and a transient version-read blip is rare + self-heals on the next tick.
  """
  @spec current_version(String.t(), String.t()) :: integer() | nil
  def current_version(user_id, note_id) do
    case Repo.with_tenant(user_id, fn ->
           Repo.one(
             from(n in Note, where: n.id == ^note_id and n.kind == "note", select: n.version)
           )
         end) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  # Returns max(inserted_at) for all crdt_update_log rows for note_id at this
  # moment, or nil when the log is empty. Uses inserted_at (timestamptz, usec
  # precision) because Postgres does not support max() on UUID columns.
  # The existing index on (note_id, inserted_at) makes this a fast index scan.
  # Called at the START of the checkpoint so the watermark marks the exact
  # boundary the snapshot covers.
  @doc false
  def tail_watermark(note_id) do
    CrdtUpdateLog
    |> where([l], l.note_id == ^note_id)
    |> select([l], max(l.inserted_at))
    |> Repo.one()
  end

  # Prune the consumed tail-log rows. Two boundary shapes:
  #
  #   * `{:ids, ids}` — delete EXACTLY these rows (detached callers). A concurrent
  #     append is not in the set, so it survives regardless of clock ties; a row
  #     that failed to decrypt was excluded by replay_tail, so it is never pruned
  #     unfolded. This is the #285 root fix.
  #   * `{:watermark, wm}` — delete rows at/below the `inserted_at` watermark
  #     (live-room callers whose doc reflects the whole tail). nil / empty set is
  #     a no-op (nothing folded yet).
  #
  # Runs inside the same `Repo.with_tenant` transaction as the notes UPDATE for
  # atomicity.
  defp prune_tail(_note_id, {:ids, []}), do: :ok

  defp prune_tail(note_id, {:ids, ids}) do
    CrdtUpdateLog
    |> where([l], l.note_id == ^note_id and l.id in ^ids)
    |> Repo.delete_all()
  end

  defp prune_tail(_note_id, {:watermark, nil}), do: :ok

  defp prune_tail(note_id, {:watermark, watermark}) do
    CrdtUpdateLog
    |> where([l], l.note_id == ^note_id and l.inserted_at <= ^watermark)
    |> Repo.delete_all()
  end
end
