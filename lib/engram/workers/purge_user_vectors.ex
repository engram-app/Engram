defmodule Engram.Workers.PurgeUserVectors do
  @moduledoc """
  Deletes every Qdrant point a deleted account owned.

  Inserted by `Engram.Accounts.Lifecycle.hard_delete/2` inside the Postgres
  delete's transaction, so it exists only once the account is gone, and
  account deletion never waits on Qdrant inside the user's request (#2182: a
  stalled Qdrant held `DELETE /api/me` for 10 s).
  Until it runs the points are unreachable: every search is scoped to a live
  user, and this user no longer exists.

  A failed delete returns an error, so Oban retries it. `OrphanSweep` is the
  backstop if every attempt fails: it reaps the points of any user id that
  has no `users` row, which this one no longer has.
  """
  # Privacy, not housekeeping: 20 attempts on Oban's exponential backoff span
  # days, so a Qdrant outage delays the purge rather than dropping it.
  use Oban.Worker, queue: :events, max_attempts: 20

  alias Engram.Vector.Qdrant

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id), do: %{"user_id" => user_id} |> new() |> Oban.insert()

  # One filter-delete with the patient indexing retries (30 s receive timeout).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}),
    do: Qdrant.delete_by_user(nil, user_id, :indexing)
end
