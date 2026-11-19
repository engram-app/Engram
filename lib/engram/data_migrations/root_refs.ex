defmodule Engram.DataMigrations.RootRefs do
  @moduledoc """
  S6 step 1b (Engram#2523): points every live root note at its vault's root
  folder row (`Engram.Folders.Rows.root_id/1`), so `folder_ref_id` places
  every live note and the root can later take `NOT NULL` (step 9) and the
  name lookup (step 7). Note writers set it from this release on
  (`Rows.ensure/4` with `root: true`); this fills the rows written before,
  and the ones a previous-release node writes during a rolling deploy or
  after a rollback (re-verified daily).

  Inert until the rollback floor reaches the readers' release
  (`Rows.root_writes?/1`): `enabled?/0` is false, so no pass runs and the
  stuck clock is held.

  Each pass, per vault, never a walk of `notes`:

    1. Discovery: at most #{200} vaults holding a live note with no
       reference whose folder envelope is the root (the complement of the
       drift predicate, `Engram.Folders.Drift`). One `notes_folder_ref_live_id`
       probe per vault (the `(vault_id, NULL)` range; drift rows are 0 in
       steady state), on the maintenance pool on SaaS and per tenant on
       self-host. Nothing found is `:done`: a daily re-verify costs one probe
       per vault.
    2. Roots: a vault with no root row gets one (`Rows.ensure_root/2`), each
       user in its own tenant transaction gated like `FolderTable`'s writes
       (`FolderTable.gated/3`: vault rows NOWAIT, then the rotation lock FOR
       SHARE), so a DEK rotation never misses the row's name. A user that
       cannot be gated now (a delete, a rotation, a folder write) is retried
       next pass; any other failure is logged.
    3. Fill: per vault, one statement under `lock_timeout = '2s'` and
       `statement_timeout = '5s'`: up to #{1_000} of those notes, read on the
       same index range and locked `FOR NO KEY UPDATE SKIP LOCKED`, get
       `folder_ref_id = vault_id`. The update names only `folder_ref_id`, so
       `seq` and `updated_at` stay (no feed or cache sees a change);
       `notes_set_name_key` re-derives the name key. At most #{2_000} rows a
       pass (non-HOT updates: autovacuum's dead tuples, as
       `NoteFolderHashNull`).

  Tombstones keep a NULL reference here (the restore trigger re-resolves a
  restored note). Step 9's `NOT NULL` must handle them first.

  Kill switch: `enabled?/0` is the `root_refs` service override (default
  on). Off, the runner runs no pass and the ledger stays open.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto.{RotationGate, RotationInProgressError}
  alias Engram.DataMigrations.FolderTable
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  require Logger

  @batch 1_000
  @max_fixed 2_000
  @vaults_per_pass 200

  @impl true
  def name, do: "root_refs"

  @impl true
  def version, do: 1

  @doc """
  Kill switch: the `root_refs` service override (default on), and the
  rollback floor at the readers' release (`Rows.root_writes?/1`). Below the
  floor the runner runs no pass and holds the stuck clock, so the open
  ledger does not page while it waits for the raise.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:root_refs, true) == true and Rows.root_writes?()

  @doc "Re-verified daily (one probe per vault): a previous-release node writes NULL root references."
  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` / `max_fixed:` override the fill size and per-pass cap.
  def run_pass(opts),
    do: pass(Keyword.get(opts, :batch, @batch), Keyword.get(opts, :max_fixed, @max_fixed))

  defp pass(batch, max_fixed) do
    case candidates() do
      [] ->
        :done

      vaults ->
        blocked =
          vaults
          |> Enum.reject(fn {_user, _vault, root?} -> root? end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.count(fn {user_id, vault_ids} -> not user_roots(user_id, vault_ids) end)

        fixed =
          Enum.reduce_while(vaults, 0, fn {user_id, vault_id, _}, fixed ->
            if fixed >= max_fixed,
              do: {:halt, fixed},
              else: {:cont, fixed + fill(user_id, vault_id, batch)}
          end)

        {:more, rows: fixed, blocked: blocked}
    end
  end

  # ---- discovery ------------------------------------------------------------

  # A live note with no reference whose folder envelope is the root, in the
  # vault bound as `:v`: one `(vault_id, NULL)` probe of the reference index.
  defp root_note_query do
    from(n in Note,
      where:
        n.vault_id == parent_as(:v).id and is_nil(n.folder_ref_id) and n.kind == "note" and
          is_nil(n.deleted_at) and
          fragment("coalesce(octet_length(?) <= 16, true)", n.folder_ciphertext),
      select: 1
    )
  end

  # `{user_id, vault_id, root_row?}` for the vaults with such a note.
  defp candidates do
    # ponytail: one index probe per vault, O(vaults) a pass, and only while
    # open or on the daily re-verify.
    from(v in Vault,
      as: :v,
      where: exists(root_note_query()),
      order_by: v.id,
      limit: @vaults_per_pass,
      select: {v.user_id, v.id, fragment("EXISTS (SELECT 1 FROM folders f WHERE f.id = ?)", v.id)}
    )
    |> TenantScan.all()
    |> Enum.take(@vaults_per_pass)
  end

  # ---- root rows ------------------------------------------------------------

  # true when the user's roots exist (or it has no user row left).
  defp user_roots(user_id, vault_ids) do
    # Read the key's version BEFORE the key (`RotationGate.check/2`).
    ctx = %{user_id: user_id, dek_version: RotationGate.dek_version(user_id)}

    case Repo.get(User, user_id) do
      nil ->
        true

      user ->
        Repo.with_tenant!(user_id, fn ->
          FolderTable.gated(Repo, ctx, fn _repo ->
            Enum.all?(vault_ids, &root!(user, &1))
          end)
        end)
    end
  rescue
    RotationInProgressError ->
      false

    # NOWAIT on a vault a delete holds, a deadlock, or a folder write in
    # flight (`Vaults.try_folder_write_locks!/2` raises 55P03 by name).
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :deadlock_detected, "55P03"],
        do: false,
        else: failed(user_id, e)
  end

  defp root!(user, vault_id) do
    case Rows.ensure_root(user, vault_id) do
      {:ok, _} -> true
      {:error, reason} -> failed(user.id, reason)
    end
  end

  defp failed(user_id, reason) do
    Logger.error(
      "root_refs: root row not created",
      Metadata.with_category(:error, :sync,
        user_id: user_id,
        reason: Metadata.safe_reason(reason)
      )
    )

    false
  end

  # ---- references -----------------------------------------------------------

  @fill_sql """
  WITH c AS MATERIALIZED (
    SELECT n.id FROM notes AS n
    WHERE n.vault_id = $1 AND n.folder_ref_id IS NULL AND n.kind = 'note'
      AND n.deleted_at IS NULL AND coalesce(octet_length(n.folder_ciphertext) <= 16, true)
      AND EXISTS (SELECT 1 FROM folders AS f WHERE f.id = $1 AND f.deleted_at IS NULL)
    ORDER BY n.id
    LIMIT $2
    FOR NO KEY UPDATE OF n SKIP LOCKED
  )
  UPDATE notes AS n SET folder_ref_id = n.vault_id
  FROM c
  WHERE n.id = c.id
  """

  @doc false
  def fill_sql, do: @fill_sql

  # Rows fixed in `vault_id`, in one short transaction on the sweep's pool.
  defp fill(user_id, vault_id, batch) do
    run = fn repo ->
      _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
      _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
      %{num_rows: fixed} = repo.query!(@fill_sql, [Ecto.UUID.dump!(vault_id), batch])
      fixed
    end

    case TenantScan.pool() do
      :per_user ->
        Repo.with_tenant!(user_id, fn -> run.(Repo) end)

      {:fleet, maintenance} ->
        {:ok, fixed} = maintenance.transaction(fn -> run.(maintenance) end)
        fixed
    end
  rescue
    # A lock wait or the statement budget: this vault is retried next pass
    # (it is still a candidate, so the ledger stays open).
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled, :deadlock_detected],
        do: 0,
        else: reraise(e, __STACKTRACE__)
  end
end
