defmodule Engram.Test.NoteCommittedDispatch do
  @moduledoc """
  Runs the pending `Engram.Workers.NoteCommitted` dispatchers.

  Every single-note content write (CRDT checkpoint, genesis body,
  `Notes.upsert_note/4`) inserts ONE `NoteCommitted` job in its own
  transaction (the R6 outbox); that job enqueues the embed, link and finalize
  jobs. Oban runs `testing: :manual` here, so a test that asserts on those
  downstream jobs after a write calls `run/0` first, as production's
  `events` queue would.
  """
  import Ecto.Query

  alias Engram.Repo
  alias Engram.Workers.NoteCommitted

  @doc "Performs and deletes every pending dispatcher. Returns how many ran."
  @spec run() :: non_neg_integer()
  def run do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == ^inspect(NoteCommitted) and j.state in ["available", "scheduled"]
        )
      )

    for job <- jobs do
      :ok = NoteCommitted.perform(job)
      Repo.delete!(job)
    end

    length(jobs)
  end
end
