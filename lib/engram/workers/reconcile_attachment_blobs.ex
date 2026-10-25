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
  memory is one page plus the keys seen. Right before each copy or
  "unrecoverable" report, the object is probed (a storage error means skip,
  not "missing") and the row, vault and user are re-checked in one query, so
  an upload or a client heal that lands mid-run is neither overwritten nor
  misreported. Nothing is restored for a soft-deleted user
  or a deleted or purging vault: account deletion wipes the prefix before
  it deletes the rows, and a copy in that window would leave current
  objects no lifecycle rule expires (OrphanSweep would be the only backstop).

  Triggers:
    * a read that finds a live row's blob missing (`Attachments.get_attachment/3`)
      enqueues one job for that vault, deduped for 10 minutes;
    * a daily cron runs the job with no args, which fans out one job per
      vault holding live attachments.

  Versions unavailable is a configuration, not a failure (an upgrade must
  need no operator action): the Database adapter, a store without versioning
  (501), a role without `s3:ListBucketVersions` (403 AccessDenied), or a
  bucket with versioning off (every listed version id is `"null"`). The job
  returns `:ok`, counts `[:engram, :attachments, :reconcile_unavailable]`
  (`reason` tag, scraped via `Engram.PromEx.Reliability`). Only the
  bucket-wide reasons (Database, 501, AccessDenied) latch the node and log at
  info once per boot; "versioning off" is read from one vault's listing, so
  it only counts. While latched, the daily cron enqueues ONE probe job (a
  one-entry listing of one vault) instead of the fan-out; a successful probe,
  or any successful per-vault listing, clears the latch so the next cron fans
  out again. Any other listing error (network, 5xx) fails the job and
  Oban retries it.
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

  # Set once this node learns bucket versions are unavailable (see moduledoc).
  @latch {__MODULE__, :unavailable}

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
  def perform(%Oban.Job{args: %{"probe" => true, "user_id" => user_id, "vault_id" => vault_id}}),
    do: probe(user_id, vault_id)

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
      # Bounded: while versions are unavailable every per-vault job would be
      # a no-op, so one cheap probe asks whether that is still true instead.
      if :persistent_term.get(@latch, nil), do: enqueue_probe(), else: fan_out()
    end
  end

  defp live_vaults_query,
    do:
      from(a in Attachment,
        where: is_nil(a.deleted_at) and not is_nil(a.storage_key),
        distinct: true,
        select: {a.user_id, a.vault_id}
      )

  defp enqueue_probe do
    case Repo.cross_tenant(fn -> Repo.maintenance().one(limit(live_vaults_query(), 1)) end) do
      nil ->
        :ok

      # Enqueue logs and counts its own failure; the next cron retries.
      {user_id, vault_id} ->
        _ =
          Engram.Notes.Enqueue.enqueue(
            new(%{"user_id" => user_id, "vault_id" => vault_id, "probe" => true}),
            "reconcile_attachment_blobs"
          )

        :ok
    end
  end

  # One listing request, one entry: does this node still lack versions? A
  # success clears the latch, so the next daily cron fans out again.
  defp probe(user_id, vault_id) do
    case Storage.adapter().list_versions("#{user_id}/#{vault_id}/objects/", max_keys: 1) do
      {:ok, _entries, _next} -> clear_unavailable()
      {:error, :unsupported} -> unavailable(:unsupported, latch: true)
      {:error, {:unsupported, reason}} when is_atom(reason) -> unavailable(reason, latch: true)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fan_out do
    Repo.cross_tenant(fn -> Repo.maintenance().all(live_vaults_query()) end)
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
    acc = %{seen: MapSet.new(), restored: 0, versioned?: false, listed?: false}

    case pages(user_id, vault_id, prefix, nil, [], acc) do
      {:ok, %{listed?: true, versioned?: false}} ->
        # Entries, but every one a "null" version and no delete marker:
        # versioning is off, so a missing blob has nothing to come back from.
        # Not an unrecoverable alert per key; the client copy is the way back.
        # (An EMPTY listing proves nothing about versioning, so it is not
        # classified here.) Per vault, never latched: one vault's history
        # says nothing about the bucket.
        unavailable(:versioning_off, latch: false)

      {:ok, %{seen: seen, restored: restored}} ->
        :ok = clear_unavailable()
        # Live keys with no entry at all, read AFTER the listing finished, so
        # an upload that landed meanwhile is caught by the exists? re-check.
        missing = for {id, key} <- live_keys(user_id, vault_id), key not in seen, do: {id, key}
        :ok = report_unrecoverable(user_id, vault_id, missing)
        log_restored(vault_id, restored)

      # Bucket-wide (the backend, a 501, a missing grant): latch the node.
      {:error, :unsupported} ->
        unavailable(:unsupported, latch: true)

      {:error, {:unsupported, reason}} when is_atom(reason) ->
        unavailable(reason, latch: true)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pages(user_id, vault_id, prefix, marker, carry, acc) do
    case Storage.adapter().list_versions(prefix, marker: marker, max_keys: page_size()) do
      {:ok, entries, next} ->
        {ready, carry} = split_carry(carry ++ entries, next)
        by_key = Enum.group_by(ready, & &1.key)

        acc = %{
          acc
          | restored: acc.restored + restore_page(user_id, vault_id, by_key),
            seen: MapSet.union(acc.seen, by_key |> Map.keys() |> MapSet.new()),
            versioned?: acc.versioned? or Enum.any?(entries, &versioned_entry?/1),
            listed?: acc.listed? or entries != []
        }

        if next,
          do: pages(user_id, vault_id, prefix, next, carry, acc),
          else: {:ok, acc}

      {:error, _} = err ->
        err
    end
  end

  # S3 gives "null" as the version id of an object written while versioning
  # was off. A delete marker or a real id means the bucket keeps versions.
  defp versioned_entry?(%{delete_marker?: true}), do: true
  defp versioned_entry?(%{version_id: id}), do: id != "null"

  # :ok, counted every time. A bucket-wide reason latches the node and logs
  # once per boot; persistent_term: one write per boot (and one erase when it
  # clears), read on every fan-out. A per-vault reason only counts.
  defp unavailable(reason, latch: false) do
    :telemetry.execute([:engram, :attachments, :reconcile_unavailable], %{count: 1}, %{
      reason: reason
    })

    :ok
  end

  defp unavailable(reason, latch: true) do
    :ok = unavailable(reason, latch: false)

    if :persistent_term.get(@latch, nil) != reason do
      :persistent_term.put(@latch, reason)

      Logger.info(
        "attachment reconcile: bucket versions unavailable, restore from versions is off",
        Metadata.with_category(:info, :sync, reason: reason)
      )
    end

    :ok
  end

  defp clear_unavailable do
    if :persistent_term.get(@latch, nil), do: :persistent_term.erase(@latch)
    :ok
  end

  @doc false
  # Tests: forget what this node learned.
  def reset_unavailable, do: clear_unavailable()

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
          |> Enum.filter(fn {id, key} ->
            restore_key({user_id, vault_id, id}, key, Map.fetch!(broken, key))
          end)
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
      else: Enum.each(missing, fn {id, key} -> restore_key({user_id, vault_id, id}, key, []) end)
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

  # true when the key was restored. Decided at copy time, per key:
  #   * the object is checked first: present (an upload or an earlier
  #     restore put one there) means nothing to do, and a storage error
  #     means "do not know", so neither a copy nor an alerted report;
  #   * then the row and account are re-checked in one query, so a client
  #     heal that moved the row to a new key, or an account deletion that
  #     began mid-page, stops this copy (both would leave a current object
  #     no row references).
  defp restore_key({user_id, vault_id, id}, key, versions) do
    with :missing <- presence(key, vault_id),
         true <- still_restorable?(user_id, vault_id, id, key) do
      newest_data =
        versions
        |> Enum.reject(& &1.delete_marker?)
        |> Enum.max_by(& &1.last_modified, fn -> nil end)

      copy_back(id, key, newest_data)
    else
      _ -> false
    end
  end

  # `Storage.presence/1`, with this worker's log on an unknown answer.
  defp presence(key, vault_id) do
    case Storage.presence(key) do
      {:error, reason} ->
        Logger.warning(
          "attachment blob probe failed, retrying on the next run",
          Metadata.with_category(:warning, :sync,
            vault_id: vault_id,
            storage_key: key,
            reason: Metadata.safe_reason(reason)
          )
        )

        :unknown

      presence ->
        presence
    end
  end

  defp still_restorable?(user_id, vault_id, id, key) do
    Repo.with_tenant!(user_id, fn ->
      Repo.exists?(
        from(a in Attachment,
          join: v in Engram.Vaults.Vault,
          on: v.id == a.vault_id,
          join: u in Engram.Accounts.User,
          on: u.id == a.user_id,
          where:
            a.id == ^id and a.vault_id == ^vault_id and a.storage_key == ^key and
              is_nil(a.deleted_at) and is_nil(v.deleted_at) and is_nil(v.purge_started_at) and
              is_nil(u.deleted_at)
        )
      )
    end)
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
