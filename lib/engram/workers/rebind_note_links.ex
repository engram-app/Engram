defmodule Engram.Workers.RebindNoteLinks do
  @moduledoc """
  Retired. Link targets now resolve on read (`Engram.Links`), so nothing
  rewrites other notes' edges when a note is created, renamed or deleted.

  Kept only so jobs enqueued by the previous release complete instead of
  failing as an unknown worker. Delete it in the release after this one.
  """

  # Priority 1: yields the shared `indexing` lane to ExtractNoteLinks (0),
  # whose edges make a just-written link resolve (ObanQueueConfigTest).
  use Oban.Worker, queue: :indexing, priority: 1, max_attempts: 1

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)

  @impl Oban.Worker
  def perform(_job), do: :ok
end
