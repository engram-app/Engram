defmodule Engram.Workers.TestWorker do
  @moduledoc """
  Minimal Oban worker to verify job processing works.
  Used in Phase 1 acceptance test, not for production.
  """
  use Oban.Worker, queue: :maintenance

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message" => _message}}) do
    :ok
  end
end
