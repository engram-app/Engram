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

  Site-specific work stays at the site: the checkpoint's announce, upsert's
  broadcast and link rebind.
  """
  alias Engram.Notes.Enqueue
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  @spec enqueue_jobs(String.t(), String.t(), keyword()) :: :ok
  def enqueue_jobs(note_id, user_id, opts \\ []) when is_binary(note_id) and is_binary(user_id) do
    _ =
      Enqueue.enqueue(
        EmbedNote.new_debounced(note_id, user_id, priority: Keyword.get(opts, :embed_priority, 0)),
        "embed_note"
      )

    # #648 lever 1: cheap edge extraction must not ride the embed debounce
    # (30s) or the embed budget gate; ~2s leading edge.
    _ = Enqueue.enqueue(ExtractNoteLinks.new_debounced(note_id, user_id), "extract_note_links")

    # #1710: move any version copy this write's transaction left behind.
    _ =
      if Keyword.fetch!(opts, :finalize?),
        do: Enqueue.enqueue(FinalizeRevision.job(note_id, user_id), "finalize_revision")

    :ok
  end
end
