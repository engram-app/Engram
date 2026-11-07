defmodule Engram.Notes.CrdtWrite do
  @moduledoc """
  The single CRDT write path for markdown content (Engram#2519, step 1).

  A REST or MCP write of a note's full text enters the Y-doc as ops: the
  incoming text is diffed hunk by hunk (`CrdtBridge.diff_hunks_into_text/2`)
  into the doc the writer's text was derived from, and the resulting Yjs
  delta is the write. Nothing writes a content snapshot of its own: the
  committed row is the checkpoint of that doc (`CrdtCheckpoint`, the same
  materializer a room uses), and a live room receives the delta itself
  (`CrdtDeliver.deliver_out/6`, `delta:`), not a copy of the stored snapshot.

  Behind the `:crdt_write_apply_text` ServiceConfig switch, default OFF
  (`enabled?/0`). Off, `Notes.upsert_note/4` and `rmw_note/5` run the
  snapshot path exactly as before.

  ## Why the room gets the delta after commit, not during the write

  The design note routes a room-resident write through the room. It cannot be
  done inside the write's transaction: the room appends through its own
  connection, and that append resets `notes.crdt_head` on the row this
  transaction holds `FOR NO KEY UPDATE` (rmw holds it from the start), so the
  room would wait on us while we wait on the room. `CrdtDeliver` already runs
  post-commit for that reason. So every write commits the same way (the delta
  checkpointed into the row, in the request), and the delta then enters a live
  room through the room. The room's own checkpoint afterwards folds bytes the
  row already holds: a compaction, never a second content write. The REST
  reply's `version`/`seq` are therefore the written values on both routes.

  ## Cost per write

  The doc load (one decrypt of the snapshot, the tail replay) and the encode
  are O(note), as on the snapshot path. The diff is a line diff bounded by a
  50 ms deadline (`Engram.Native.text_hunks/2`), coarser past it, never wrong.
  Under the lock: one `lock_note_seq/2` (no body read) and one tail read; then
  the checkpoint's own statements. No statement scans the vault.
  """

  alias Engram.{Crypto, Repo, ServiceConfig}
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, Note, NoteBody}

  @switch :crdt_write_apply_text

  @doc "Whether markdown content writes take this path (ServiceConfig, default off)."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(@switch, false) == true

  @doc """
  Apply `new_text` (full note text, already scrubbed and size-checked) to the
  markdown `note` as Yjs ops, inside the caller's tenant transaction.

  Options:

    * `actor:` (required) the history actor, as `Notes.upsert_note/4`.
    * `recording:` the caller's `Revisions.recording?/1`, decided before its
      transaction (#1710); read here when absent.
    * `base:` the doc `new_text` was derived from. `{:doc, doc}` (a
      read-modify-write's authority, or the doc a matched `base_hash` names):
      the change is authored against it and Yjs merges it with anything that
      landed since. `:current` (default): the doc as loaded now, snapshot plus
      tail (last writer wins, but never against a stale snapshot).

  Returns `{:ok, %{outcome: :noop}}` when the doc already holds `new_text`
  (no op is minted), `{:ok, %{outcome: :applied, note: row, delta: delta}}`
  with the committed row, `{:error, :stale_snapshot}` when the row moved
  between the caller's read and the lock (the caller re-reads), or
  `{:error, :checkpoint_skipped}` (nothing was written).
  """
  @spec apply_text(map(), Note.t(), String.t(), keyword()) ::
          {:ok, %{outcome: :noop} | %{outcome: :applied, note: Note.t(), delta: binary()}}
          | {:error, :stale_snapshot | :checkpoint_skipped | term()}
  def apply_text(user, %Note{} = note, new_text, opts) when is_binary(new_text) do
    checkpoint_opts =
      [actor: Keyword.fetch!(opts, :actor), outbox: false, announce: false] ++
        Keyword.take(opts, [:recording])

    with {:ok, doc, folded} <- base_doc(user, note, Keyword.get(opts, :base, :current)) do
      if CrdtBridge.project_doc(doc) == new_text do
        {:ok, %{outcome: :noop}}
      else
        sv = Yex.encode_state_vector!(doc)
        :ok = CrdtBridge.ingest_plaintext(doc, new_text, diff: :hunks)
        delta = Yex.encode_state_as_update!(doc, sv)
        persist(user, note, doc, delta, folded, checkpoint_opts)
      end
    end
  end

  defp base_doc(_user, _note, {:doc, %Yex.Doc{} = doc}), do: {:ok, doc, []}

  defp base_doc(user, note, :current) do
    with {:ok, state} <- Crypto.decrypt_crdt_state(note, user),
         {:ok, doc} <- CrdtBridge.doc_from_state(state) do
      {:ok, doc, CrdtPersistence.replay_tail(doc, user, note.id, note.vault_id)}
    end
  end

  # Vault then note, FOR NO KEY UPDATE (every writer's order). A changed seq
  # means a content write or a delete committed since the caller's read: its
  # base check and no-op check are stale, so it re-reads (two identical writes
  # from one base must not both apply, or the text doubles). Tail rows that
  # landed since are another client's edits: folded in as concurrent ops, and
  # pruned with the rest by the checkpoint, which prunes only what `doc` holds.
  defp persist(user, note, doc, delta, folded, checkpoint_opts) do
    if Notes.lock_note_seq(note.id, note.vault_id) == note.seq do
      known = MapSet.new(folded)

      rows =
        note.id
        |> CrdtPersistence.tail_rows(note.vault_id)
        |> Enum.reject(&MapSet.member?(known, &1.id))

      applied = CrdtPersistence.apply_tail_rows(doc, user, note.id, rows)

      case CrdtCheckpoint.checkpoint_pruning(
             user.id,
             note.vault_id,
             note.id,
             doc,
             [prune_ids: folded ++ applied] ++ checkpoint_opts
           ) do
        {:written, _pruned} ->
          row = NoteBody.get(note.id)
          :ok = Repo.after_commit(fn -> on_written(user, row) end)
          {:ok, %{outcome: :applied, note: row, delta: delta}}

        :skipped ->
          {:error, :checkpoint_skipped}
      end
    else
      {:error, :stale_snapshot}
    end
  end

  @written_event [:engram, :notes, :crdt_write, :written]

  @doc false
  # The ONE post-write step of this path, run after the write commits. The
  # shared post-write hook of #2523 S1 (`Engram.Search.NameTerms.on_note_written/2`)
  # is called from here once it merges; until then it emits the event the seam
  # test pins, so the call site cannot silently disappear. `row` is the
  # committed (still encrypted) row.
  @spec on_written(map(), Note.t()) :: :ok
  def on_written(_user, %Note{id: id}) do
    :telemetry.execute(@written_event, %{count: 1}, %{note_id: id})
  end
end
