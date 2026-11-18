defmodule Engram.DataMigrations.RootRefs do
  @moduledoc """
  S6 step 1b (Engram#2523): points every live root note at its vault's root
  folder row (`Engram.Folders.Rows.root_id/1`), so `folder_ref_id` places
  every live note and the root can later take `NOT NULL` (step 9) and the
  name lookup (step 7). Note writers set it from this release on
  (`Rows.ensure/4` with `root: true`); this fills the rows written before,
  and the ones a previous-release node writes during a rolling deploy or
  after a rollback (re-verified daily).

  Each pass, two phases:

    1. Roots: the vaults holding a live note with no reference and no root
       row yet get one (`Rows.ensure_root/2`), at most #{200} vaults a pass,
       each user in its own tenant transaction gated like `FolderTable`'s
       writes (`FolderTable.gated/3`: vault rows NOWAIT, then the rotation
       lock FOR SHARE), so a DEK rotation never misses the row's name. A
       user that cannot be gated now (a delete, a rotation, a folder write)
       is retried next pass. Discovery reads every vault once (a primary-key
       probe of `folders` and one `notes_folder_ref_live_id` probe each),
       on the maintenance pool on SaaS and per tenant on self-host.
    2. Fill: `Engram.Backfill.IdWindows.heal_pass/4` over `notes` (windows of
       #{1_000} ids). Each window is one statement under `SET LOCAL
       lock_timeout = '2s'` and `statement_timeout = '5s'`: the window's live
       notes with no reference whose folder envelope is the root (the
       complement of the drift predicate, `Engram.Folders.Drift`) and whose
       root row exists get `folder_ref_id = vault_id`, locked `FOR NO KEY
       UPDATE SKIP LOCKED`. A skipped row, or one whose root row phase 1 has
       not made yet, counts as left and keeps the ledger open. The update
       names only `folder_ref_id`: `seq` and `updated_at` stay, so no feed
       or cache sees a change; `notes_set_name_key` re-derives the name key.
       Capped at #{2_000} rows a pass (non-HOT updates: autovacuum's dead
       tuples, as `NoteFolderHashNull`).

  Tombstones keep a NULL reference here (the restore trigger re-resolves a
  restored note). Step 9's `NOT NULL` must handle them first.

  Kill switch: `enabled?/0` is the `root_refs` service override (default
  on). Off, the runner runs no pass and the ledger stays open.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.{IdWindows, TenantScan}
  alias Engram.Crypto.{RotationGate, RotationInProgressError}
  alias Engram.DataMigrations.FolderTable
  alias Engram.Folders.{Folder, Rows}
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  require Logger

  @batch 1_000
  @max_fixed 2_000
  @roots_per_pass 200

  @impl true
  def name, do: "root_refs"

  @impl true
  def version, do: 1

  @doc "Kill switch: the `root_refs` service override (default on)."
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:root_refs, true) == true

  @doc "Re-verified daily: a previous-release node writes NULL root references."
  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` / `max_fixed:` override the window size and per-pass cap.
  def run_pass(opts) do
    blocked = create_roots()

    case IdWindows.heal_pass(name(), Note, &fill/2,
           batch_size: Keyword.get(opts, :batch, @batch),
           max_fixed: Keyword.get(opts, :max_fixed, @max_fixed)
         ) do
      :done when blocked == 0 -> :done
      :done -> {:more, rows: 0, blocked: blocked}
      {:more, more} -> {:more, Keyword.put(more, :blocked, blocked)}
    end
  end

  # ---- phase 1: root rows ---------------------------------------------------

  # Returns the users it could not gate this pass.
  defp create_roots do
    # ponytail: reads every vault (a pk probe and an index probe each) per
    # open pass; the ledger closes once, so O(vaults) a pass is fine.
    from(v in Vault,
      as: :v,
      where:
        not exists(from(f in Folder, where: f.id == parent_as(:v).id, select: 1)) and
          exists(
            from(n in Note,
              where:
                n.vault_id == parent_as(:v).id and is_nil(n.folder_ref_id) and
                  n.kind == "note" and is_nil(n.deleted_at),
              select: 1
            )
          ),
      order_by: v.id,
      limit: @roots_per_pass,
      select: {v.user_id, v.id}
    )
    |> TenantScan.all()
    |> Enum.take(@roots_per_pass)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.count(fn {user_id, vault_ids} -> not user_roots(user_id, vault_ids) end)
  end

  # true when the user's roots exist (or it has no key, so no notes).
  defp user_roots(user_id, vault_ids) do
    # Read the key's version BEFORE the key (`RotationGate.check/2`).
    ctx = %{user_id: user_id, dek_version: RotationGate.dek_version(user_id)}

    case Repo.get(User, user_id) do
      nil ->
        true

      user ->
        Repo.with_tenant!(user_id, fn ->
          FolderTable.gated(Repo, ctx, fn _repo ->
            Enum.all?(vault_ids, &match?({:ok, _}, Rows.ensure_root(user, &1)))
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

  # ---- phase 2: references --------------------------------------------------

  # A live root note with no reference, in the window (`n`).
  @candidate """
  n.id = ANY($1) AND n.kind = 'note' AND n.deleted_at IS NULL AND n.folder_ref_id IS NULL
    AND coalesce(octet_length(n.folder_ciphertext) <= 16, true)
  """

  @fill_sql """
  WITH c AS MATERIALIZED (
    SELECT n.id FROM notes AS n, folders AS f
    WHERE #{@candidate} AND f.id = n.vault_id AND f.deleted_at IS NULL
    ORDER BY n.id
    FOR NO KEY UPDATE OF n SKIP LOCKED
  )
  UPDATE notes AS n SET folder_ref_id = n.vault_id
  FROM c
  WHERE n.id = c.id
  """

  @left_sql "SELECT count(*)::int FROM notes AS n WHERE #{@candidate}"

  defp fill(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{num_rows: fixed} = repo.query!(@fill_sql, [ids])
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    {fixed, left > 0}
  end
end
