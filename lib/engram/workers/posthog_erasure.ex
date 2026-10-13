defmodule Engram.Workers.PostHogErasure do
  @moduledoc """
  Deletes a PostHog person (and its events) out of band.

  Used where the inline delete is not enough or not safe to block on:

    * account erasure re-runs it 10 minutes later, so a `PostHogPersonSync`
      batch that read the user before the delete cannot leave a resurrected
      person behind (the sync's timeout is 5 minutes);
    * an email change erases the person keyed on the OLD email, which account
      erasure would otherwise never find;
    * an analytics opt-out.

  Args carry the keyed analytics id, never the email.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Engram.Observability.PostHog

  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(email, opts \\ []) when is_binary(email) do
    %{"distinct_id" => PostHog.analytics_id(email)}
    |> new(opts)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"distinct_id" => distinct_id}}) do
    PostHog.delete_person(distinct_id)
  end
end
