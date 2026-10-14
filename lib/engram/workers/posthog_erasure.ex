defmodule Engram.Workers.PostHogErasure do
  @moduledoc """
  Deletes PostHog persons (and their events) by distinct id. Enqueued only by
  `Engram.Analytics.forget/1`; see there for when and why it runs twice.

  A failed delete returns an error, so Oban retries it. Args carry keyed
  analytics ids and the legacy Clerk id, never an email.
  """
  # Erasure is a legal obligation: 20 attempts on Oban's exponential backoff
  # span days, so a PostHog outage delays it rather than dropping it.
  use Oban.Worker, queue: :events, max_attempts: 20

  alias Engram.Observability.PostHog

  @spec enqueue([String.t()], keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(distinct_ids, opts \\ []) when is_list(distinct_ids) do
    %{"distinct_ids" => distinct_ids}
    |> new(opts)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"distinct_ids" => ids}}) do
    Enum.find(Enum.map(ids, &PostHog.delete_person/1), :ok, &(&1 != :ok))
  end
end
