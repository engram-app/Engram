defmodule Engram.Workers.DropUserVectors do
  @moduledoc """
  Drops every Qdrant point a deleted account owns, out of band.

  `Accounts.Lifecycle` enqueues this from soft-delete (once `deleted_at` is
  stamped) and from hard-delete's commit branch. It used to call
  `Qdrant.delete_by_user/3` inline, inside the DELETE /api/me request, with
  the 5s fail-fast profile and no retry, twice per delete: a slow Qdrant held
  the request ~10s and a failed drop was simply lost until OrphanSweep.

  Unique per `user_id` while a job is pending, so the soft + hard pair of one
  delete call inserts one job. `Qdrant.delete_by_user/3` is a filter delete,
  so a repeat run (Oban retry, or a hard delete long after an inactivity
  soft delete) is a no-op.

  A job is only ever inserted after the delete it serves took effect, and
  `perform/1` re-checks it anyway: an account that is live again (or never
  stopped being) is skipped, never wiped.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [keys: [:user_id], period: :infinity, states: :incomplete]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Logger.Metadata
  alias Engram.Vector.Qdrant

  require Logger

  # One filter-delete call; the patient `:indexing` profile bounds it well
  # under this. Oban's default is :infinity (see Engram.ObanWorkerTimeoutTest).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id), do: %{user_id: user_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user_uncached(user_id) do
      %User{deleted_at: nil} -> {:cancel, :user_live}
      _gone_or_soft_deleted -> drop(user_id)
    end
  end

  defp drop(user_id) do
    case Qdrant.delete_by_user(nil, user_id, :indexing) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Qdrant clear failed after account delete",
          Metadata.with_category(:error, :lifecycle,
            user_id: user_id,
            reason: Metadata.safe_reason(reason)
          )
        )

        error
    end
  end
end
