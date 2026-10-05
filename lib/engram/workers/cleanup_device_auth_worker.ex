defmodule Engram.Workers.CleanupDeviceAuthWorker do
  @moduledoc """
  Cleanup of expired auth state every 15 minutes — both the legacy device
  flow (`Engram.Auth.DeviceFlow`) and the OAuth 2.1 server (`Engram.OAuth`).
  """
  # A slow run absorbs the next tick; a failing DELETE waits for the next
  # tick rather than retrying 20 times.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 600, states: [:available, :scheduled, :executing]]

  alias Engram.Auth.DeviceFlow
  alias Engram.OAuth

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {device, _} = DeviceFlow.cleanup_expired()
    {oauth, _} = OAuth.cleanup_expired()

    if device + oauth > 0,
      do: Logger.info("cleanup_device_auth device_rows=#{device} oauth_rows=#{oauth}")

    :ok
  end
end
