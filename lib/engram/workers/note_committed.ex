defmodule Engram.Workers.NoteCommitted do
  @moduledoc """
  The jobs of a write that changed a note's content, as one job: the outbox
  row of every single-note content write (CRDT checkpoint, genesis body,
  `Notes.upsert_note/4`).

  The write inserts it with `insert!/3` INSIDE its own transaction (R6), so
  the job commits or rolls back with the write: no committed content change
  without its embed and link work, and the reconcile sweep is only a
  backstop. One plain insert, never the three unique inserts: a unique
  insert takes an advisory lock held to the end of the enclosing
  transaction (a second writer to the same note would skip its debounce
  move), and `EmbedNote.insert_debounced/3` is ~12 queries under the vault
  seq lock (#1710).

  This job runs `Engram.Notes.ContentCommit.enqueue_jobs/3` with the write's
  own arguments. Each downstream job keeps its own uniqueness and args, so
  two writes still collapse into one embed and one link job. The embed
  debounce starts when this job runs rather than at the commit, which is the
  queue latency later.
  """
  use Oban.Worker, queue: :events, max_attempts: 10

  import Ecto.Query, only: [from: 2]

  alias Engram.Notes.ContentCommit

  @doc "The dispatcher job for a checkpoint of `note_id` that changed its content."
  @spec job(String.t(), String.t(), keyword()) :: Oban.Job.changeset()
  def job(note_id, user_id, opts) when is_binary(note_id) and is_binary(user_id) do
    priority = Keyword.fetch!(opts, :embed_priority)

    args = %{
      note_id: note_id,
      user_id: user_id,
      embed_priority: priority,
      finalize: Keyword.fetch!(opts, :finalize?)
    }

    # `:agent` (an MCP write, #2294). The previous release ignores the key
    # and settles for the default.
    args =
      if opts[:embed_settle], do: Map.put(args, :embed_settle, opts[:embed_settle]), else: args

    # At the embed's own rank: every content checkpoint passes through this
    # queue, so an interactive edit must not wait FIFO behind a first-sync
    # flood's dispatchers (EmbedNote.priority_for/1).
    new(args, priority: priority)
  end

  @doc """
  Inserts `job/3` in the caller's transaction (the outbox). Raises on a
  failed insert, so the write rolls back with its job rather than committing
  without it. Never through `Engram.Notes.Enqueue`: its retry and rescue
  would hide an aborted transaction from the caller.
  """
  @spec insert!(String.t(), String.t(), keyword()) :: Oban.Job.t()
  def insert!(note_id, user_id, opts) do
    {:ok, job} = Oban.insert(job(note_id, user_id, opts))
    job
  end

  @doc """
  Deletes a job `insert!/3` wrote ahead of a write that then changed nothing
  (a lost fence, a create that raced), in the same transaction. By id, so
  another write's job for the note is never touched.
  """
  @spec discard!(Oban.Job.t()) :: :ok
  def discard!(%Oban.Job{id: id}) do
    {_, _} = Engram.Repo.delete_all(from(j in Oban.Job, where: j.id == ^id))
    :ok
  end

  # Three inserts; finite so a stuck one cannot pin an events slot (#1496).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id, "user_id" => user_id} = args}) do
    ContentCommit.enqueue_jobs(note_id, user_id,
      embed_priority: args["embed_priority"],
      finalize?: args["finalize"],
      embed_settle: settle(args["embed_settle"])
    )
  end

  defp settle("agent"), do: :agent
  defp settle(_), do: nil
end
