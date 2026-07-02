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
  alias Engram.Notes.{CrdtBridge, CrdtUpdateLog, Enqueue, Helpers, Note}
  alias Engram.Workers.EmbedNote

  require Logger

  @doc """
  Checkpoint the live doc into the `notes` row. Encrypts the full Yjs v1
  state, prunes the tail-log, and — when the projected text actually changed —
  re-materializes plaintext columns, bumps version/seq, and enqueues a
  debounced embed. When the text is unchanged (hash match) it degrades to a
  snapshot-compaction write with NO version/seq churn, so calling it on every
  room exit is cheap.

  Options: `:watermark` — a pre-captured prune boundary (max inserted_at of
  the tail rows the doc already reflects). When omitted, it is captured here
  BEFORE the doc is encoded, so rows landing mid-encode survive the prune.

  Never called per-keystroke — driven by `CrdtCheckpointTimer` (debounced)
  and by `CrdtPersistence.unbind/3` on room exit. Never raises: any internal
  failure is logged and returns `:ok` (safe in the room's terminate path).
  """
  @spec checkpoint(String.t(), String.t(), String.t(), Yex.Doc.t(), keyword()) :: :ok
  def checkpoint(user_id, vault_id, note_id, %Yex.Doc{} = doc, opts \\ []) do
    user = Accounts.get_user!(user_id)

    # Capture the prune watermark BEFORE reading/encoding the doc. Any tail row
    # inserted while we encode is NOT necessarily in the snapshot, so it must
    # survive the prune (it replays on next bind — apply_update is idempotent).
    watermark =
      case Keyword.fetch(opts, :watermark) do
        {:ok, wm} ->
          wm

        :error ->
          # A capture failure degrades to nil: prune becomes a no-op, which is the
          # safe direction (rows are kept and replayed on next bind).
          case Repo.with_tenant(user_id, fn -> tail_watermark(note_id) end) do
            {:ok, wm} -> wm
            _ -> nil
          end
      end

    text = CrdtBridge.text_of(doc)

    IO.puts("CHECKPOINT-DIAG note=#{note_id} text=#{inspect(text)}")

    with {:ok, raw_state} <- encode(doc),
         {_flat_doc, state} <- maybe_flatten(doc, raw_state, note_id),
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(state, user, note_id),
         {:ok, key} <- Crypto.dek_content_hash_key(user) do
      content_hash = Crypto.hmac_content_hash(key, text)
      tags = Helpers.extract_tags(text)

      # with_tenant wraps the fun's return in {:ok, _} (Ecto transaction) — the fun returns the bare hash.
      {:ok, prev_hash} =
        Repo.with_tenant(user_id, fn ->
          # `note.path` / `note.folder` / `note.title` are VIRTUAL — a bare
          # Repo.get! leaves them nil. Materialize through the decrypt path so
          # they are populated BEFORE we re-derive title + re-HMAC path/folder.
          # Without this, extract_title falls back to the UUID and
          # inject_phase_b_fields_pub gets nil path/folder → corrupts
          # path_hmac/folder_hmac so the row stops resolving by path.
          {:ok, note} = Crypto.maybe_decrypt_note_fields(Repo.get!(Note, note_id), user)
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

            prune_tail(note_id, watermark)
            prev
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
              |> Map.put(:crdt_state_ciphertext, ct)
              |> Map.put(:crdt_state_nonce, nonce)
              |> Map.put(:content_hash, content_hash)

            note
            |> Note.changeset(Map.put(phase_b, :version, note.version + 1))
            |> Ecto.Changeset.put_change(:seq, Vaults.next_seq!(vault_id))
            |> Repo.update!()

            prune_tail(note_id, watermark)
            prev
          end
        end)

      _ =
        if prev_hash != content_hash do
          Enqueue.enqueue(EmbedNote.new_debounced(note_id), "embed_note")
        end

      :ok
    else
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

  # Prune only the tail-log rows captured by this snapshot's watermark.
  # Rows inserted after the watermark survive for the next checkpoint/replay —
  # they are NOT yet folded into the snapshot and must not be discarded.
  # When watermark is nil (log was empty), there is nothing to delete.
  # Runs inside the same `Repo.with_tenant` transaction as the notes UPDATE
  # for atomicity.
  defp prune_tail(_note_id, nil), do: :ok

  defp prune_tail(note_id, watermark) do
    CrdtUpdateLog
    |> where([l], l.note_id == ^note_id and l.inserted_at <= ^watermark)
    |> Repo.delete_all()
  end
end
