defmodule Engram.Workers.IndexCapMaintenance do
  @moduledoc """
  Moves the two bulk index-cap sweeps off the request path.

  Both were previously inline, and both are O(the user's whole vault):

    * `:revoke_dense` — after a downgrade, drop every dense vector the user is
      no longer entitled to. Ran synchronously inside the Paddle webhook, where
      a 60k-note UPDATE can outlive the webhook timeout and get the delivery
      recorded as failed even though the cancellation committed.

    * `:backfill_slots` — after a delete frees a capped slot, re-open the note
      that inherits it. Ran once per DELETED note, so a 5,000-note folder
      delete ran it 5,000 times over the same rows.

  `unique` collapses a burst to one job per user per kind: the work is
  idempotent and whole-vault, so running it once after the burst is both
  cheaper and more correct than running it per row. `states: :incomplete` means
  a *completed* job does not block a later one, so a second delete an hour on
  still gets its backfill.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:user_id, :kind], period: 120, states: :incomplete]

  alias Engram.Indexing.IndexCap

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc """
  Enqueue a sweep. Never raises — the callers are a webhook handler and a
  delete worker, and neither should fail because a follow-up sweep could not
  be queued.
  """
  @spec enqueue(Ecto.UUID.t(), :revoke_dense | :backfill_slots) :: :ok
  def enqueue(user_id, kind)
      when is_binary(user_id) and kind in [:revoke_dense, :backfill_slots] do
    %{user_id: user_id, kind: Atom.to_string(kind)}
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "kind" => "revoke_dense"}}) do
    IndexCap.revoke_dense_index(user_id)
  end

  def perform(%Oban.Job{args: %{"user_id" => user_id, "kind" => "backfill_slots"}}) do
    IndexCap.backfill_freed_slots(user_id)
  end
end
