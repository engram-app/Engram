defmodule Engram.DataMigrations.FolderMarkerDelete do
  @moduledoc """
  Deletes the `kind = 'folder'` marker rows once markers have stopped (S6
  step 4, Engram#2523): every listing reads `folders.explicit` (phase 1) and
  no writer inserts a marker (phase 2, `Engram.Folders.MarkerStop`), so a
  marker is redundant with its folder row. `done?/0` is what the step 3 write
  stop (`PathHashStop`) waits for: a vault-wide marker read is cheap only once
  none are left.

  Blocked (the pass walks nothing, resets its walk and stays open) unless
  `MarkerStop.on?/0`: never while any writer can still insert a marker.

  Per marker, before it goes, its folder row is made to carry the flag on its
  own, with `explicit_seq` stamped (0 unless set), so `ExplicitFolderReconcile`
  never clears it:

    * a LIVE marker needs its live, explicit folder row at its path hash. A
      vault holding ANY live marker without one is not touched at all on
      this pass (redundancy pre-check, logged with the vault id and the
      count): an unmatched marker is never deleted, and it keeps the ledger
      open until `FolderTable` or a writer repairs the row;
    * a TOMBSTONED marker of an undoable delete (`delete_op_id`) marks the
      folder row that delete stamped with the same op and path hash explicit,
      so the undo (`Folders.restore_op/3`) brings the empty folder back from
      the row. Other tombstones just go.

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`notes` primary-key windows of 200; one fleet walk on the maintenance pool
  on SaaS, per tenant on self-host). Each window is one transaction under
  `SET LOCAL lock_timeout = '2s'` and `statement_timeout = '5s'`, with the
  ordering `ExplicitFolderReconcile` uses: first the window's vault rows
  `FOR SHARE SKIP LOCKED` in their own statement, then the checks and writes
  in later statements, whose fresh snapshots see every write committed
  before the lock (every folder and marker writer takes its vault row first).
  A row a writer holds, or a vault one holds, is skipped and counts as left.

  Kill switch: `enabled?/0` is the `folder_marker_delete` service override,
  DEFAULT OFF: it is switched on in prod only once release E is verified and
  the re-probe in #2523 reads 0. Off, no pass runs and the ledger stays open.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.Folders.MarkerStop
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note

  require Logger

  @batch 200

  @impl true
  def name, do: "folder_marker_delete"

  @impl true
  def version, do: 1

  @doc "True once no marker row is left (the ledger is done)."
  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  @doc """
  Kill switch: the `folder_marker_delete` service override, default OFF.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:folder_marker_delete, false) == true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size.
  def run_pass(opts) do
    if MarkerStop.on?() do
      IdWindows.heal_pass(name(), Note, &delete/2, batch_size: Keyword.get(opts, :batch, @batch))
    else
      IdWindows.reset_walk(name())
      :ok = Engram.DataMigration.report(blocked: :markers_not_stopped)
      {:more, rows: 0, blocked: 1}
    end
  end

  # Statement 1: the vault rows of the window's markers, FOR SHARE SKIP
  # LOCKED, in a statement of their own so the later ones take their
  # snapshot after the lock (see `ExplicitFolderReconcile`).
  @lock_vaults_sql """
  SELECT id FROM vaults
  WHERE id IN (SELECT vault_id FROM notes WHERE id = ANY($1) AND kind = 'folder')
  FOR SHARE SKIP LOCKED
  """

  # Statement 2: the locked vaults holding a live marker with no live
  # explicit folder row at its path hash, and how many such markers each
  # has. Vault-wide, on `notes_user_vault_folder_marker` and
  # `folders_full_path`: O(the vault's markers), once a window.
  @unmatched_sql """
  SELECT m.vault_id, count(*)::int FROM notes AS m
  WHERE m.vault_id = ANY($1) AND m.kind = 'folder' AND m.deleted_at IS NULL
    AND m.user_id = (SELECT v.user_id FROM vaults AS v WHERE v.id = m.vault_id)
    AND NOT EXISTS (
      SELECT 1 FROM folders AS f
      WHERE f.vault_id = m.vault_id AND f.full_path_hmac = m.folder_hmac
        AND f.deleted_at IS NULL AND f.explicit)
  GROUP BY m.vault_id
  """

  # Statement 3: the window's markers in the vaults that passed (`$2`),
  # locked, then the folder rows stamped, then the markers deleted. A
  # data-modifying CTE runs once whether or not it is referenced, in the same
  # snapshot; the two stamps touch disjoint rows (live ones, deleted ones).
  @delete_sql """
  WITH m AS MATERIALIZED (
    SELECT n.id, n.vault_id, n.folder_hmac, n.deleted_at, n.delete_op_id FROM notes AS n
    WHERE n.id = ANY($1) AND n.kind = 'folder' AND n.vault_id = ANY($2)
    ORDER BY n.id
    FOR UPDATE OF n SKIP LOCKED
  ), live AS (
    UPDATE folders AS f SET explicit_seq = 0
    FROM m
    WHERE m.deleted_at IS NULL AND f.vault_id = m.vault_id
      AND f.full_path_hmac = m.folder_hmac AND f.deleted_at IS NULL AND f.explicit
      AND f.explicit_seq IS NULL
    RETURNING f.id
  ), tomb AS (
    UPDATE folders AS f SET explicit = true, explicit_seq = coalesce(f.explicit_seq, 0)
    FROM m
    WHERE m.deleted_at IS NOT NULL AND m.delete_op_id IS NOT NULL
      AND f.vault_id = m.vault_id AND f.full_path_hmac = m.folder_hmac
      AND f.delete_op_id = m.delete_op_id AND f.deleted_at IS NOT NULL
    RETURNING f.id
  )
  DELETE FROM notes AS n
  USING m
  WHERE n.id = m.id
  """

  # What is left in a window: any marker (a skipped lock or an unmatched vault).
  @left_sql "SELECT count(*)::int FROM notes WHERE id = ANY($1) AND kind = 'folder'"

  @doc false
  def delete_sql, do: @delete_sql

  defp delete(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])

    case repo.query!(@lock_vaults_sql, [ids]) do
      %{rows: []} ->
        {0, left?(repo, ids)}

      %{rows: locked} ->
        vaults = List.flatten(locked)
        %{rows: unmatched} = repo.query!(@unmatched_sql, [vaults])
        Enum.each(unmatched, fn [vault, count] -> log_unmatched(vault, count) end)
        ok = vaults -- Enum.map(unmatched, &hd/1)
        %{num_rows: fixed} = repo.query!(@delete_sql, [ids, ok])
        {fixed, left?(repo, ids)}
    end
  end

  defp left?(repo, ids) do
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    left > 0
  end

  defp log_unmatched(vault, count) do
    Logger.warning(
      "folder_marker_delete: vault skipped, live markers without an explicit folder row",
      Metadata.with_category(:warning, :data,
        vault_id: Ecto.UUID.load!(vault),
        count: count
      )
    )
  end
end
