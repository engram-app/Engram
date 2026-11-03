defmodule Engram.Workers.ReleaseRebuildHeld do
  @moduledoc """
  Hourly cron: frees the jobs `Engram.Rebuild.hold/1` parked while the v5
  rebuild was `on` (bulk repaths, DEK rotations), once it no longer is.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(_job) do
    released = Engram.Rebuild.release_held()
    Logger.info("rebuild_held_release released=#{released} holding=#{Engram.Rebuild.holding?()}")
    :ok
  end
end
