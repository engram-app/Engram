defmodule Engram.Workers.AccountExport do
  @moduledoc """
  Streams a user's vaults into a multi-part zip on S3.

  Filled out in Task 12 + 13. Currently a placeholder that Export.request/1
  can enqueue against.
  """

  use Oban.Worker,
    queue: :export,
    max_attempts: 3,
    unique: [fields: [:args], period: :infinity]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => _id}}) do
    # Filled in by Task 12.
    :ok
  end
end
