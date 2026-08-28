defmodule Engram.Workers.CleanupDeviceAuthWorker do
  @moduledoc """
  Hourly cleanup of expired auth state — both the legacy device flow
  (`Engram.Auth.DeviceFlow`) and the OAuth 2.1 server (`Engram.OAuth`).
  """
  use Oban.Worker, queue: :maintenance

  alias Engram.Auth.DeviceFlow
  alias Engram.OAuth

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = DeviceFlow.cleanup_expired()
    _ = OAuth.cleanup_expired()
    :ok
  end
end
