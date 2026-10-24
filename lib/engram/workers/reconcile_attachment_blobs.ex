defmodule Engram.Workers.ReconcileAttachmentBlobs do
  @moduledoc """
  Restores the blob of a LIVE attachment row from bucket versioning (#2159).

  A live row whose current object is a delete marker is broken: every read
  of it fails. In a versioned bucket the bytes are still there as a
  noncurrent version until the lifecycle rule expires them. Per vault, this
  lists every version under `<user>/<vault>/objects/`, and for each live
  row's key whose latest entry is a delete marker it copies the newest DATA
  version back on top (CopyObject; never DeleteObjectVersion, so the app
  needs no permanent-delete permission). The restored rows then get a fresh
  seq so clients pull them again. A live key with no data version left is
  logged as `attachment blob unrecoverable`.

  Scope comes from live rows only: a tombstone's key is never restored, its
  blob is `Engram.Workers.AttachmentBlobGC`'s to reap.

  Triggers:
    * a read that finds a live row's blob missing (`Attachments.get_attachment/3`)
      enqueues one job for that vault, deduped for 10 minutes;
    * a daily cron runs the job with no args, which fans out one job per
      vault holding live attachments.

  An unversioned backend (`Engram.Storage.Database`) answers
  `{:error, :unsupported}` and the job is a no-op.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:vault_id], period: 600]

  import Ecto.Query

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Storage

  require Logger

  # Jobs per `Oban.insert_all` in the fan-out (same bound as the notes path).
  @insert_chunk 2_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @doc "Queues a reconcile of one vault (deduped for 10 minutes)."
  @spec enqueue(String.t(), String.t()) :: :ok
  def enqueue(user_id, vault_id) do
    _ =
      Engram.Notes.Enqueue.enqueue(
        new(%{"user_id" => user_id, "vault_id" => vault_id}),
        "reconcile_attachment_blobs"
      )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}),
    do: reconcile(user_id, vault_id)

  def perform(%Oban.Job{}) do
    if Repo.tenancy_unsafe?() do
      Logger.error(
        "reconcile_attachment_blobs refusing to fan out: RLS is enforced and no maintenance " <>
          "pool is configured, so no vault would look like it holds attachments",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      fan_out()
    end
  end

  defp fan_out do
    query =
      from(a in Attachment,
        where: is_nil(a.deleted_at) and not is_nil(a.storage_key),
        distinct: true,
        select: {a.user_id, a.vault_id}
      )

    Repo.cross_tenant(fn -> Repo.maintenance().all(query) end)
    |> Enum.map(fn {user_id, vault_id} ->
      new(%{"user_id" => user_id, "vault_id" => vault_id})
    end)
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(&Oban.insert_all/1)
  end

  defp reconcile(user_id, vault_id) do
    case Storage.adapter().list_versions("#{user_id}/#{vault_id}/objects/") do
      {:ok, versions} -> restore(user_id, vault_id, Enum.group_by(versions, & &1.key))
      {:error, :unsupported} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore(user_id, vault_id, versions_by_key) do
    restored =
      user_id
      |> live_keys(vault_id)
      |> Enum.filter(fn {id, key} -> restore_key(id, key, Map.get(versions_by_key, key, [])) end)
      |> Enum.map(&elem(&1, 0))

    if restored != [] do
      _ = Attachments.bump_seqs(user_id, vault_id, restored)

      Logger.info(
        "attachment blobs restored from bucket versions",
        Metadata.with_category(:info, :sync, vault_id: vault_id, total_count: length(restored))
      )
    end

    :ok
  end

  defp live_keys(user_id, vault_id) do
    Repo.with_tenant!(user_id, fn ->
      Repo.all(
        from(a in Attachment,
          where:
            a.user_id == ^user_id and a.vault_id == ^vault_id and is_nil(a.deleted_at) and
              not is_nil(a.storage_key),
          select: {a.id, a.storage_key}
        )
      )
    end)
  end

  # true when the key was restored. A key whose latest entry is data is fine.
  defp restore_key(id, key, versions) do
    latest = Enum.find(versions, & &1.latest?)

    if latest && not latest.delete_marker? do
      false
    else
      newest_data =
        versions
        |> Enum.reject(& &1.delete_marker?)
        |> Enum.max_by(& &1.last_modified, fn -> nil end)

      copy_back(id, key, newest_data)
    end
  end

  defp copy_back(id, _key, nil) do
    Logger.error(
      "attachment blob unrecoverable",
      Metadata.with_category(:error, :sync, attachment_id: id)
    )

    false
  end

  defp copy_back(id, key, %{version_id: version_id}) do
    case Storage.adapter().restore_version(key, version_id) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "attachment blob restore failed, retrying on the next run",
          Metadata.with_category(:warning, :sync,
            attachment_id: id,
            reason: Metadata.safe_reason(reason)
          )
        )

        false
    end
  end
end
