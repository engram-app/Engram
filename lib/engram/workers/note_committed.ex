defmodule Engram.Workers.NoteCommitted do
  @moduledoc """
  The post-commit jobs of a CRDT checkpoint that changed a note's content, as
  one job.

  A checkpoint used to insert EmbedNote, ExtractNoteLinks and FinalizeRevision
  itself, after its transaction: three unique inserts plus the embed clamp
  read, 12 queries on every checkpoint. It now inserts this job (one plain
  insert, still after the commit, so the work stays out from under the vault
  seq lock, #1710) and this job runs `Engram.Notes.ContentCommit.enqueue_jobs/3`
  with the checkpoint's own arguments. Each downstream job keeps its own
  uniqueness and args, so two checkpoints still collapse into one embed and
  one link job.

  The embed debounce starts when this job runs rather than at the commit,
  which is the queue latency later.
  """
  use Oban.Worker, queue: :events, max_attempts: 10

  alias Engram.Notes.ContentCommit

  @doc "The dispatcher job for a checkpoint of `note_id` that changed its content."
  @spec job(String.t(), String.t(), keyword()) :: Oban.Job.changeset()
  def job(note_id, user_id, opts) when is_binary(note_id) and is_binary(user_id) do
    priority = Keyword.fetch!(opts, :embed_priority)

    # At the embed's own rank: every content checkpoint passes through this
    # queue, so an interactive edit must not wait FIFO behind a first-sync
    # flood's dispatchers (EmbedNote.priority_for/1).
    new(
      %{
        note_id: note_id,
        user_id: user_id,
        embed_priority: priority,
        finalize: Keyword.fetch!(opts, :finalize?)
      },
      priority: priority
    )
  end

  # Three inserts; finite so a stuck one cannot pin an events slot (#1496).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id, "user_id" => user_id} = args}) do
    ContentCommit.enqueue_jobs(note_id, user_id,
      embed_priority: args["embed_priority"],
      finalize?: args["finalize"]
    )
  end
end
