defmodule Engram.Workers.CleanupDeviceAuthWorker do
  @moduledoc "Hourly cleanup of expired device authorizations and revoked refresh tokens."
  use Oban.Worker, queue: :maintenance

  alias Engram.Auth.DeviceFlow

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = DeviceFlow.cleanup_expired()
    :ok
  end
end
