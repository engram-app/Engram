defmodule Engram.Workers.DeleteNoteIndex do
  @moduledoc """
  Oban worker: deletes Qdrant points and DB chunks for a soft-deleted note.

  Enqueued from Notes.delete_note/3 instead of a fire-and-forget Task,
  ensuring testability (Oban manual mode) and retry on transient failures.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  alias Engram.Indexing

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "note_id" => note_id,
          "user_id" => user_id,
          "vault_id" => vault_id,
          "path" => path
        }
      }) do
    note = %{id: note_id, user_id: user_id, vault_id: vault_id, path: path}
    Indexing.delete_note_index(note)
    :ok
  end
end
