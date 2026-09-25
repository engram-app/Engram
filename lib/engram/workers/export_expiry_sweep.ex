defmodule Engram.Workers.ExportExpirySweep do
  @moduledoc """
  Daily sweep of expired account exports (#859, "Task 15" in AccountExport).

  An export archive is a complete copy of a user's personal data; the
  download window is 7 days (`expires_at` stamped by AccountExport). Rows
  past the window flip `:expired` FIRST — `mint_download_url` gates on
  `:ready`, so a half-deleted archive is never offered for download — then
  their S3 blobs are deleted and cleared from `s3_keys`.

  Failure semantics:

    * A failed or malformed key entry is RETAINED on the (now `:expired`)
      row with a per-key warning, and the next run retries it — the sweep
      also picks up `:expired` rows whose `s3_keys` is non-empty. Rows are
      never cleared while a blob might survive (that would orphan personal
      data in S3 with no record left to reap it).
    * A raise while sweeping one export is caught + logged and the loop
      continues — one bad export never blocks every other user's cleanup.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts.Export.Schema
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    if tenancy_unsafe?() do
      # Filtered by the tenant policy, the read below returns [] and the sweep
      # reports success while archives of personal data stay in S3 forever.
      Logger.error(
        "export_expiry_sweep refusing to run: RLS is enforced and no maintenance pool is " <>
          "configured, so the expired-export read would return zero rows",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      sweep()
    end
  end

  # Same gate as `OrphanSweep`: the fallback `Repo` is only correct where RLS
  # is not enforced.
  defp tenancy_unsafe? do
    Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?()
  end

  # Every query runs on `Repo.maintenance()`: this sweep spans tenants by
  # definition. `cross_tenant/1` is a no-op on the maintenance pool and silences
  # the app tripwire on the `Repo` fallback, which the gate above allows only
  # where RLS is not enforced.
  defp sweep do
    adapter = Engram.Storage.adapter()
    repo = Repo.maintenance()
    now = DateTime.utc_now()

    expired =
      Repo.cross_tenant(fn ->
        repo.all(
          from(e in Schema,
            where:
              (e.status == :ready and e.expires_at <= ^now) or
                (e.status == :expired and fragment("array_length(?, 1) > 0", e.s3_keys))
          )
        )
      end)

    Enum.each(expired, fn export ->
      try do
        sweep_export(adapter, repo, export)
      rescue
        error ->
          Logger.error(
            "export_expiry_sweep: sweep raised, continuing with remaining exports",
            Metadata.with_category(:error, :data,
              user_id: export.user_id,
              reason: Metadata.safe_reason(error)
            )
          )
      end
    end)

    :ok
  end

  defp sweep_export(adapter, repo, %Schema{} = export) do
    # Expire BEFORE deleting: from this point the archive is not
    # downloadable regardless of how far the blob deletes get.
    {:ok, export} =
      if export.status == :ready do
        export
        |> Schema.changeset(%{status: :expired})
        |> save(repo)
      else
        {:ok, export}
      end

    results = Enum.map(export.s3_keys || [], &delete_blob(adapter, &1))
    remaining = for {:failed, entry, _reason} <- results, do: entry

    for {:failed, entry, reason} <- results do
      Logger.warning(
        "export_expiry_sweep: blob delete failed, key retained for next run",
        Metadata.with_category(:warning, :data,
          user_id: export.user_id,
          reason: Metadata.safe_reason(reason),
          key_present: is_binary(entry["key"])
        )
      )
    end

    {:ok, _} =
      export
      |> Schema.changeset(%{s3_keys: remaining})
      |> save(repo)

    :ok
  end

  defp save(changeset, repo), do: Repo.cross_tenant(fn -> repo.update(changeset) end)

  defp delete_blob(adapter, %{"key" => key} = entry) when is_binary(key) do
    case adapter.delete(key) do
      :ok -> {:ok, entry}
      {:error, reason} -> {:failed, entry, reason}
      other -> {:failed, entry, other}
    end
  end

  # Malformed entry (no usable key): keep it + warn every run rather than
  # silently counting it deleted — the blob may still exist in S3.
  defp delete_blob(_adapter, entry), do: {:failed, entry, :missing_key}
end
