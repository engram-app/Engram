defmodule Engram.Notes.ContentCommit do
  @moduledoc """
  The post-commit work every committed note CONTENT change needs, in one place.

  Called by the single-note write sites (the CRDT checkpoint, and both
  content branches of `Notes.upsert_note/4`) after the write's transaction
  commits, only when the content hash actually changed. The batch path keeps
  its own bulk `Oban.insert_all` version for throughput.

  Site-specific work stays at the site: the checkpoint's announce, upsert's
  broadcast and link rebind.
  """
  alias Engram.Notes.Enqueue
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, FinalizeRevision}

  @spec after_commit(String.t(), String.t(), keyword()) :: :ok
  def after_commit(note_id, user_id, opts \\ []) when is_binary(note_id) and is_binary(user_id) do
    _ =
      Enqueue.enqueue(
        EmbedNote.new_debounced(note_id, user_id, priority: Keyword.get(opts, :embed_priority, 0)),
        "embed_note"
      )

    # #648 lever 1: cheap edge extraction must not ride the embed debounce
    # (30s) or the embed budget gate; ~2s leading edge.
    _ = Enqueue.enqueue(ExtractNoteLinks.new_debounced(note_id, user_id), "extract_note_links")

    # #1710: move any version copy this write's transaction left behind.
    _ = Enqueue.enqueue(FinalizeRevision.new_for_note(note_id, user_id), "finalize_revision")

    :ok
  end
end
