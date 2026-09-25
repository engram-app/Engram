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

  import Ecto.Query

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

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crypto_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => id} = args}) do
    case owner(args) do
      # Row gone (user hard-deleted mid-export). Nothing to do.
      nil -> :ok
      {:error, _} = error -> error
      user_id -> run(id, user_id)
    end
  end

  defp run(id, user_id) do
    with {:ok, export} <- fetch_for_worker(id, user_id),
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
        handle_failure(id, user_id, reason)
    end
  end

  defp owner(%{"user_id" => user_id}), do: user_id

  # Jobs enqueued before `user_id` joined the args (#1758). The owner is what
  # this read discovers, so no tenant can scope it; hence the maintenance pool.
  # ponytail: legacy bridge, delete once no pre-#1758 export job can be in flight.
  #
  # Refuses where RLS is enforced and no maintenance pool exists: there the read
  # returns nil, which is indistinguishable from "row gone", and the export
  # would sit :pending forever behind `account_exports_one_active_per_user`.
  defp owner(%{"export_id" => id}) do
    if Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?() do
      {:error, :tenancy_unsafe}
    else
      Repo.cross_tenant(fn ->
        Repo.maintenance().one(from(e in Schema, where: e.id == ^id, select: e.user_id))
      end)
    end
  end

  defp fetch_for_worker(id, user_id) do
    case Repo.with_tenant!(user_id, fn -> Repo.get(Schema, id) end) do
      nil ->
        {:error, :not_found}

      %Schema{} = schema ->
        {:ok, Repo.preload(schema, :user)}
    end
  end

  defp save(changeset),
    do: Repo.with_tenant!(changeset.data.user_id, fn -> Repo.update(changeset) end)

  defp mark_running(%Schema{} = export) do
    export
    |> Schema.changeset(%{status: :running})
    |> save()
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
    |> save()
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
  defp handle_failure(id, user_id, reason) do
    case Repo.with_tenant!(user_id, fn -> Repo.get(Schema, id) end) do
      nil ->
        :ok

      %Schema{} = export ->
        export
        |> Schema.changeset(%{
          status: :failed,
          error_reason: inspect(reason)
        })
        |> save()
    end

    {:error, reason}
  end
end
