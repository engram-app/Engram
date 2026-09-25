defmodule Engram.Workers.CleanupVault do
  @moduledoc """
  Oban worker: hard-deletes all data for a soft-deleted vault after the retention period.

  Scheduled 30 days after soft-delete. If the vault has been restored (deleted_at cleared)
  or doesn't exist, the job is a no-op.

  Cleanup order:
  1. Collect storage keys from DB (before deleting rows)
  2. Qdrant points (best-effort, non-fatal)
  3. DB records in a transaction: chunks → notes → attachments → api_key_vaults → vault
  4. Storage blobs (post-commit, best-effort) — only after DB is authoritative
  """

  # Deliberately NO Oban `unique` key: a restore-then-re-delete cycle needs a
  # second scheduled job while the first (now no-op) one still exists, and
  # uniqueness over :scheduled would silently drop it — losing the cleanup.
  # Duplicate-run safety comes from the DB transaction instead: the second
  # run's `Repo.delete!` hits StaleEntryError on the vanished row and rolls
  # back (same reasoning documented in BackfillCrdtHead/BackfillCrdtState).
  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Vaults.Vault

  require Logger

  @retention_days 30
  @retention_secs @retention_days * 86_400

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crypto_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @doc """
  Enqueues a CleanupVault job scheduled 30 days from now.
  """
  def enqueue(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id}
    |> new(scheduled_at: DateTime.add(DateTime.utc_now(), @retention_days, :day))
    |> Oban.insert()
  end

  @doc """
  Enqueues an immediate (unscheduled) force-purge. Used by the "delete
  permanently now" path — bypasses the retention age guard.
  """
  def enqueue_now(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id, force: true}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id} = args}) do
    perform_cleanup(vault_id, user_id, force: Map.get(args, "force", false))
  end

  @doc false
  def perform_cleanup(vault_id, user_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    # Tenant-scoped, and this load is the linchpin. Unscoped it was FILTERED to
    # nil rather than rejected, and the `is_nil(vault)` clause below reads nil
    # as "already cleaned up" — so the job logged at :debug, returned `:ok`,
    # and deleted nothing. Every observable said the cleanup ran while the
    # user's data survived.
    vault = Repo.with_tenant!(user_id, fn -> Repo.get(Vault, vault_id) end)

    # A scoped load cannot return another tenant's vault, so `nil` is now
    # ambiguous: the vault may be genuinely gone, or it may exist and belong to
    # someone else (forged args, or crossed wires). Those deserve very
    # different reactions — one is routine, the other is a security event — so
    # the ambiguity is resolved rather than collapsed into "skipping".
    foreign_owner_id = if is_nil(vault), do: foreign_owner(vault_id, user_id)

    cond do
      # Defense in depth, and the reason the scoped load did not simply delete
      # this branch. Never hard-delete another tenant's vault.
      #
      # Honest limitation, now narrowed: the probe runs on `Repo.maintenance()`,
      # so it answers correctly wherever a maintenance pool is configured. Only
      # with RLS enforced AND no maintenance pool is a forged job
      # indistinguishable from a deleted vault, falling through to the `:ok`
      # branch. It refuses to delete either way — it just cannot say why.
      not is_nil(foreign_owner_id) ->
        Logger.error(
          "CleanupVault: owner mismatch — discarding",
          Metadata.with_category(:error, :oban,
            vault_id: vault_id,
            user_id: user_id,
            reason_label: :owner_mismatch
          )
        )

        {:discard, :owner_mismatch}

      is_nil(vault) ->
        Logger.debug(
          "CleanupVault: vault not found — skipping",
          Metadata.with_category(:debug, :oban, vault_id: vault_id)
        )

        :ok

      is_nil(vault.deleted_at) ->
        Logger.debug(
          "CleanupVault: vault was restored — skipping",
          Metadata.with_category(:debug, :oban, vault_id: vault_id)
        )

        :ok

      not force and retention_age_secs(vault) < @retention_secs ->
        snooze = @retention_secs - retention_age_secs(vault)

        Logger.debug(
          "CleanupVault: vault not yet at retention — snoozing",
          Metadata.with_category(:debug, :oban, vault_id: vault_id, duration_ms: snooze * 1000)
        )

        {:snooze, snooze}

      true ->
        Logger.info(
          "CleanupVault: starting hard-delete",
          Metadata.with_category(:info, :oban, vault_id: vault_id)
        )

        run_cleanup(vault)
    end
  end

  defp retention_age_secs(vault) do
    DateTime.diff(DateTime.utc_now(), vault.deleted_at, :second)
  end

  # Returns the real owner's id when `vault_id` exists but belongs to someone
  # other than `user_id`, else nil. Only called when the tenant-scoped load
  # came back nil, to tell "already gone" from "not yours".
  #
  # `cross_tenant/1` and not `with_tenant/2`: the whole question is about a row
  # outside the caller's tenant, so there is no tenant that could scope it.
  #
  # On `Repo.maintenance()` because `cross_tenant/1` suppresses only the
  # application guard and sets no Postgres session state. On the app pool once
  # RLS actually applies, this returns nil unconditionally and the caller's
  # `owner_mismatch` branch becomes UNREACHABLE — a forged job targeting another
  # tenant's vault would be indistinguishable from a routine already-deleted
  # one and log at :debug. No data-loss risk either way (the delete at the
  # bottom of this module is properly tenant-scoped), but losing the security
  # signal silently is the whole failure mode of engram-app/Engram#1746.
  #
  # Falls back to `Repo` when no maintenance pool is configured, which is the
  # pre-cutover state the caller's limitation note describes.
  defp foreign_owner(vault_id, user_id) do
    repo = Repo.maintenance()

    Repo.cross_tenant(fn ->
      case repo.get(Vault, vault_id) do
        nil -> nil
        %Vault{user_id: owner} -> if to_string(owner) == to_string(user_id), do: nil, else: owner
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_cleanup(vault) do
    # Collect storage keys BEFORE deleting DB rows
    storage_keys = collect_storage_keys(vault)

    # Qdrant is best-effort — okay to do before DB transaction since
    # Qdrant points are derived data that can be re-indexed
    delete_qdrant_points(vault)

    # DB transaction: delete all rows, making DB authoritative.
    #
    # `with_tenant/2` IS the transaction — it opens one — so this replaces the
    # bare `Repo.transaction/1` rather than nesting inside it. Every write
    # below needs the tenant: a filtered `delete_all` reports `{0, nil}` with
    # no error, and `Repo.delete!(vault)` carries no bypass at all, so a
    # filtered delete would raise `Ecto.StaleEntryError` instead.
    Repo.with_tenant(vault.user_id, fn ->
      vault_id = vault.id

      # Drop the owner's live-note counter by the notes this vault still holds
      # as live (deleted_at IS NULL). Soft-deleted notes were already
      # decremented at soft-delete time, so only the live set counts here.
      live_notes =
        Repo.one(
          from(n in Note,
            where:
              n.vault_id == ^vault_id and is_nil(n.deleted_at) and
                n.kind == "note",
            select: count(n.id)
          )
        ) || 0

      Chunk
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all()

      Note
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all()

      :ok = UsageMeters.dec_notes_count(vault.user_id, live_notes)

      Attachment
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all()

      # `api_key_vaults` carries no RLS policy, so the guard never fires for it
      # and the option here is inert either way. Left as-is to keep this diff
      # to the queries that were actually broken.
      from(akv in "api_key_vaults", where: akv.vault_id == type(^vault_id, Ecto.UUID))
      |> Repo.delete_all(skip_tenant_check: true)

      Repo.delete!(vault)
    end)

    # Post-commit: delete storage blobs (best-effort)
    # If this fails, we have orphan blobs but no ghost rows — safe to retry
    delete_storage_blobs(storage_keys)

    # Actual user-facing lifecycle event: the vault and all its data are gone.
    Logger.info(
      "CleanupVault: vault permanently deleted",
      Metadata.with_category(:info, :lifecycle, vault_id: vault.id, user_id: vault.user_id)
    )

    :ok
  end

  # Runs BEFORE the delete transaction, so it needs its own scope. Unscoped it
  # returned `[]`, and the blobs for every attachment in the vault were left
  # in S3 with no row pointing at them — unreachable by any other cleanup path
  # except the weekly orphan sweep.
  defp collect_storage_keys(vault) do
    Repo.with_tenant!(vault.user_id, fn ->
      Attachment
      |> where(vault_id: ^vault.id)
      |> where([a], not is_nil(a.storage_key))
      |> select([a], a.storage_key)
      |> Repo.all()
    end)
  end

  defp delete_qdrant_points(vault) do
    case Engram.Vector.Qdrant.delete_by_vault(to_string(vault.user_id), to_string(vault.id)) do
      :ok ->
        Logger.debug(
          "CleanupVault: deleted Qdrant points",
          Metadata.with_category(:debug, :oban, vault_id: vault.id)
        )

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: Qdrant delete failed",
          Metadata.with_category(:warning, :oban,
            vault_id: vault.id,
            reason: Metadata.safe_reason(reason)
          )
        )
    end
  rescue
    e ->
      Logger.warning(
        "CleanupVault: Qdrant delete raised",
        Metadata.with_category(:warning, :oban,
          vault_id: vault.id,
          reason: Metadata.safe_reason(e)
        )
      )
  end

  defp delete_storage_blobs(keys) do
    Enum.each(keys, &delete_storage_blob/1)
  end

  defp delete_storage_blob(key) do
    case Engram.Storage.adapter().delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: storage delete failed",
          Metadata.with_category(:warning, :oban,
            storage_key: key,
            reason: Metadata.safe_reason(reason)
          )
        )
    end
  rescue
    e ->
      Logger.warning(
        "CleanupVault: storage delete raised",
        Metadata.with_category(:warning, :oban, storage_key: key, reason: Metadata.safe_reason(e))
      )
  end
end
