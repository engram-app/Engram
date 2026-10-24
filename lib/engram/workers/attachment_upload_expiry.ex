defmodule Engram.Workers.AttachmentUploadExpiry do
  @moduledoc """
  Hourly sweep of abandoned chunked-upload sessions. A session idle for 24h
  (`put_part` bumps `updated_at`, so active uploads are kept) is dropped
  through `Uploads.expire/1`: the row is deleted first, then the multipart
  upload is aborted (or the assembled object deleted). A completed session
  (kept so a retried complete gets its attachment) loses only its row, 24h
  after it completed: its blob is the attachment's. Storage failures are
  logged and skipped; the bucket lifecycle rule is the backstop.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @cutoff_hours 24
  @batch 100

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    if Repo.tenancy_unsafe?() do
      # Filtered by the tenant policy, the scan would return [] and report success.
      Logger.error(
        "attachment_upload_expiry refusing to run: RLS is enforced and no maintenance pool is configured",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      sweep(DateTime.add(DateTime.utc_now(), -@cutoff_hours * 3600, :second))
    end
  end

  # Pages until a scan finds nothing. Terminates: expire/1 removes the row even
  # when storage fails, and a raising row is skipped via `seen`.
  defp sweep(cutoff, seen \\ []) do
    repo = Repo.maintenance()

    batch =
      Repo.cross_tenant(fn ->
        repo.all(
          from(u in Upload,
            where: u.updated_at < ^cutoff and u.id not in ^seen,
            order_by: u.updated_at,
            limit: @batch
          )
        )
      end)

    if batch == [] do
      :ok
    else
      Enum.each(batch, &expire/1)
      sweep(cutoff, seen ++ Enum.map(batch, & &1.id))
    end
  end

  defp expire(up) do
    Uploads.expire(up)
  rescue
    error ->
      Logger.error(
        "attachment_upload_expiry: expire raised, continuing",
        Metadata.with_category(:error, :sync,
          user_id: up.user_id,
          reason: Metadata.safe_reason(error)
        )
      )
  end
end
