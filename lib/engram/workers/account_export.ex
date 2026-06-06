defmodule Engram.Workers.AccountExport do
  @moduledoc """
  Streams a user's vaults into a multi-part zip on S3.

  Happy-path scope (Task 12):

  1. Loads the `account_exports` row.
  2. Flips status pending → running.
  3. Delegates to `Engram.Accounts.Export.Streamer.run/2` to stream each
     vault as one S3 multipart upload.
  4. Persists the resulting `s3_keys` + `size_bytes` and flips status
     to `:ready` with a 7-day `expires_at`.

  Decryption (Task 13), 10 GB part split + error paths (Task 14), and
  the "export ready" email (Task 16) are stubbed pending their tasks.
  """

  use Oban.Worker,
    queue: :export,
    max_attempts: 3,
    unique: [fields: [:args], period: :infinity]

  alias Engram.Accounts.Export.Schema
  alias Engram.Accounts.Export.Streamer
  alias Engram.Repo

  # 10 GB. The Streamer doesn't honour this yet (Task 14) — it ships a
  # single part per vault — but we plumb the option so the worker contract
  # is stable across the split.
  @part_max_bytes 10_000_000_000

  # Ready exports stay downloadable for 7 days, after which
  # `ExportExpirySweep` (Task 15) tombstones the row + deletes the s3
  # blobs.
  @ready_ttl_seconds 7 * 86_400

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => id}}) do
    with {:ok, export} <- fetch_for_worker(id),
         :ok <- abort_stale_multiparts(export),
         {:ok, running} <- mark_running(export),
         {:ok, parts, total_bytes} <- Streamer.run(running, part_max_bytes: @part_max_bytes),
         {:ok, ready} <- mark_ready(running, parts, total_bytes),
         :ok <- maybe_send_email(ready) do
      :ok
    else
      {:error, :not_found} ->
        # User was hard-deleted mid-export. Nothing to do.
        :ok

      {:error, reason} ->
        handle_failure(id, reason)
    end
  end

  defp fetch_for_worker(id) do
    case Repo.get(Schema, id, skip_tenant_check: true) do
      nil ->
        {:error, :not_found}

      %Schema{} = schema ->
        {:ok, Repo.preload(schema, :user, skip_tenant_check: true)}
    end
  end

  defp mark_running(%Schema{} = export) do
    export
    |> Schema.changeset(%{status: :running})
    |> Repo.update(skip_tenant_check: true)
  end

  defp mark_ready(%Schema{} = export, parts, total_bytes) do
    now = DateTime.utc_now()

    export
    |> Schema.changeset(%{
      status: :ready,
      s3_keys: parts,
      s3_upload_ids: [],
      size_bytes: total_bytes,
      ready_at: now,
      expires_at: DateTime.add(now, @ready_ttl_seconds, :second)
    })
    |> Repo.update(skip_tenant_check: true)
  end

  # Task 14 fills this in (looks at `s3_upload_ids` and calls
  # `Storage.adapter().abort_multipart_upload/2` so a previous attempt
  # crash doesn't leave dangling parts).
  defp abort_stale_multiparts(_export), do: :ok

  # Task 16 wires `Engram.Mailer.send_export_ready/2`. No-op for now
  # so the happy path completes end-to-end without dragging in mailer
  # setup.
  defp maybe_send_email(_export), do: :ok

  # Minimal failure handling. Task 14 expands this with abort-multipart
  # + structured error categorisation. For now we just tombstone the
  # row so the user sees `:failed` instead of a stuck `:running`, and
  # bubble the original error up to Oban so retry/backoff still kicks
  # in.
  defp handle_failure(id, reason) do
    case Repo.get(Schema, id, skip_tenant_check: true) do
      nil ->
        :ok

      %Schema{} = export ->
        export
        |> Schema.changeset(%{
          status: :failed,
          error_reason: inspect(reason)
        })
        |> Repo.update(skip_tenant_check: true)
    end

    {:error, reason}
  end
end
