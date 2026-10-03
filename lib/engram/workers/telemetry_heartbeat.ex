defmodule Engram.Workers.TelemetryHeartbeat do
  @moduledoc """
  Daily self-host census ping. Fire-and-forget: a failed send is dropped and
  tomorrow's run tries again, so an air-gapped install never errors or retries.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Engram.Telemetry.Heartbeat

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Result deliberately dropped: the next daily run is the retry.
    _ = if Heartbeat.enabled?(), do: Heartbeat.send_ping()
    :ok
  end
end
