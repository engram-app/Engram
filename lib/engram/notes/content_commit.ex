defmodule Engram.Notes.ContentCommit do
  @moduledoc """
  The jobs every note CONTENT change needs, in one place.

  Called by the single-note write sites (the CRDT checkpoint, through the
  `Engram.Workers.NoteCommitted` job it inserts, and both content branches of
  `Notes.upsert_note/4`) only when the content hash actually changed. The call may run inside an enclosing tenant transaction
  (an MCP tool call is one), and that is fine: the jobs then commit or roll
  back atomically with the write (`engram_app` may insert into `oban_jobs`).

  `:finalize?` is required: `Engram.Notes.Revisions.finalize?/3` for the
  write, so a create or a write history did not record enqueues no
  `FinalizeRevision`.

  `:embed_settle` is passed to `EmbedNote.new_debounced/3` as `settle:`
  (`:agent` for an MCP write; absent means the default settle).

  Returns the first failed insert, if any; the inline write sites ignore it
  (Enqueue logs it), the dispatcher job fails on it so Oban retries.

  Site-specific work stays at the site: the checkpoint's announce, upsert's
  broadcast and link rebind.
  """
  alias Engram.Jobs
  alias Engram.Notes.Enqueue
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  @spec enqueue_jobs(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def enqueue_jobs(note_id, user_id, opts \\ []) when is_binary(note_id) and is_binary(user_id) do
    [
      EmbedNote.insert_debounced(note_id, user_id,
        priority: Keyword.get(opts, :embed_priority, 0),
        settle: Keyword.get(opts, :embed_settle)
      ),
      # #648 lever 1: cheap edge extraction must not ride the embed debounce
      # (30s) or the embed budget gate; ~2s leading edge.
      Enqueue.enqueue(ExtractNoteLinks.new_debounced(note_id, user_id), "extract_note_links"),
      # #1710: move any version copy this write's transaction left behind.
      if(Keyword.fetch!(opts, :finalize?),
        do: Enqueue.enqueue(FinalizeRevision.job(note_id, user_id), "finalize_revision"),
        else: {:ok, :skipped}
      )
    ]
    # Every insert is attempted; the first failure is returned (already
    # logged by Enqueue). Each job is unique, so a caller that retries the
    # whole set (Workers.NoteCommitted) does not duplicate the ones that landed.
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  @doc """
  `enqueue_jobs/3` for many notes of one user at once, without the finalize
  job (its only caller, a trash restore, never records a version): one
  chunked bulk insert per worker instead of two unique inserts per note.

  `entries` is `[{note_id, embed_priority}]`. `insert_all` ignores `unique`,
  so each worker's pending ids are dropped first, the way its own `unique`
  would: `EmbedNote.reject_already_queued/2` (which also promotes a pending
  job ranked worse than the new priority, so a restore never inherits a
  backfill slot) and `Jobs.reject_pending/3` for the link extraction.
  Raises on a database error: called inside the caller's transaction, the
  jobs commit or roll back with it.
  """
  @spec enqueue_jobs_bulk([{String.t(), non_neg_integer()}], String.t()) :: :ok
  def enqueue_jobs_bulk([], _user_id), do: :ok

  def enqueue_jobs_bulk(entries, user_id) when is_binary(user_id) do
    embeds =
      entries
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.flat_map(fn {priority, ids} ->
        ids
        |> EmbedNote.reject_already_queued(priority)
        |> Enum.map(&EmbedNote.new_debounced(&1, user_id, priority: priority))
      end)

    links =
      ExtractNoteLinks
      |> Jobs.reject_pending(Enum.map(entries, &elem(&1, 0)), executing: false)
      |> Enum.map(&ExtractNoteLinks.new_debounced(&1, user_id))

    _ = Jobs.insert_chunked(embeds ++ links)
    :ok
  end
end
