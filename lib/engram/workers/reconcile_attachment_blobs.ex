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

  Guards: the listing is paged (1,000 entries) and decided page by page, so
  memory is one page plus the keys seen. Rows are read after each page is
  listed and each key is re-checked with `exists?` right before a copy or
  an "unrecoverable" report, so an upload that lands mid-run is neither
  overwritten nor misreported. Nothing is restored for a soft-deleted user
  or a deleted or purging vault: account deletion wipes the prefix before
  it deletes the rows, and a copy in that window would leave current
  objects no lifecycle rule expires (OrphanSweep would be the only backstop).

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

  # Pages through the vault's versions, deciding each page as it lands, so a
  # job holds one page (plus the keys seen so far) rather than the whole
  # vault's history. A key's entries can span two pages: the last key of a
  # truncated page is carried into the next one before it is decided.
  defp reconcile(user_id, vault_id) do
    prefix = "#{user_id}/#{vault_id}/objects/"

    case pages(user_id, vault_id, prefix, nil, [], MapSet.new(), 0) do
      {:ok, seen, restored} ->
        # Live keys with no entry at all, read AFTER the listing finished, so
        # an upload that landed meanwhile is caught by the exists? re-check.
        missing = for {id, key} <- live_keys(user_id, vault_id), key not in seen, do: {id, key}
        :ok = report_unrecoverable(user_id, vault_id, missing)
        log_restored(vault_id, restored)

      {:error, :unsupported} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pages(user_id, vault_id, prefix, marker, carry, seen, restored) do
    case Storage.adapter().list_versions(prefix, marker: marker, max_keys: page_size()) do
      {:ok, entries, next} ->
        {ready, carry} = split_carry(carry ++ entries, next)
        by_key = Enum.group_by(ready, & &1.key)
        restored = restored + restore_page(user_id, vault_id, by_key)
        seen = MapSet.union(seen, by_key |> Map.keys() |> MapSet.new())

        if next,
          do: pages(user_id, vault_id, prefix, next, carry, seen, restored),
          else: {:ok, seen, restored}

      {:error, _} = err ->
        err
    end
  end

  # Holds back the last key of a truncated page: its next entries may be on
  # the following page.
  defp split_carry(entries, nil), do: {entries, []}
  defp split_carry([], _next), do: {[], []}

  defp split_carry(entries, _next) do
    last = List.last(entries).key
    Enum.split_with(entries, &(&1.key != last))
  end

  defp page_size, do: Application.get_env(:engram, :reconcile_versions_page, 1_000)

  # Restores this page's broken keys. Decided against rows read NOW (after
  # the page was listed), and refused outright for an account or vault on its
  # way out: account deletion wipes the prefix before it deletes the rows, and
  # a restore in that window would bring back current objects for a deleted
  # account that no lifecycle rule expires.
  defp restore_page(user_id, vault_id, by_key) do
    broken =
      for {key, entries} <- by_key, broken?(entries), into: %{}, do: {key, entries}

    cond do
      broken == %{} ->
        0

      leaving?(user_id, vault_id) ->
        0

      true ->
        restored =
          user_id
          |> live_keys(vault_id, Map.keys(broken))
          |> Enum.filter(fn {id, key} -> restore_key(id, key, Map.fetch!(broken, key)) end)
          |> Enum.map(&elem(&1, 0))

        Attachments.bump_seqs(user_id, vault_id, restored)
    end
  end

  # The latest entry is a delete marker (or the key has no latest flagged).
  defp broken?(entries) do
    case Enum.find(entries, & &1.latest?) do
      %{delete_marker?: false} -> false
      _ -> true
    end
  end

  defp leaving?(user_id, vault_id) do
    user_gone? =
      case Engram.Accounts.get_user_uncached(user_id) do
        %{deleted_at: nil} -> false
        _ -> true
      end

    user_gone? or
      not Repo.with_tenant!(user_id, fn ->
        Repo.exists?(
          from(v in Engram.Vaults.Vault,
            where: v.id == ^vault_id and is_nil(v.deleted_at) and is_nil(v.purge_started_at)
          )
        )
      end)
  end

  defp log_restored(_vault_id, 0), do: :ok

  defp log_restored(vault_id, restored) do
    Logger.info(
      "attachment blobs restored from bucket versions",
      Metadata.with_category(:info, :sync, vault_id: vault_id, total_count: restored)
    )
  end

  defp report_unrecoverable(_user_id, _vault_id, []), do: :ok

  defp report_unrecoverable(user_id, vault_id, missing) do
    if leaving?(user_id, vault_id),
      do: :ok,
      else: Enum.each(missing, &unrecoverable_unless_present/1)
  end

  # Re-checked: an upload may have put the object there since the listing.
  defp unrecoverable_unless_present({id, key}) do
    if Storage.adapter().exists?(key), do: :ok, else: copy_back(id, key, nil)
  end

  defp live_keys(user_id, vault_id, keys \\ nil) do
    query =
      from(a in Attachment,
        where:
          a.user_id == ^user_id and a.vault_id == ^vault_id and is_nil(a.deleted_at) and
            not is_nil(a.storage_key),
        select: {a.id, a.storage_key}
      )

    query = if keys, do: where(query, [a], a.storage_key in ^keys), else: query
    Repo.with_tenant!(user_id, fn -> Repo.all(query) end)
  end

  # true when the key was restored. Re-checked at copy time: an upload or an
  # earlier restore may have put a current object there since the listing.
  defp restore_key(id, key, versions) do
    if Storage.adapter().exists?(key) do
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
