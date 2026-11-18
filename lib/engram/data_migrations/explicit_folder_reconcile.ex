defmodule Engram.DataMigrations.ExplicitFolderReconcile do
  @moduledoc """
  Clears `folders.explicit` on every live folder row that no live
  `kind = 'folder'` marker names (S6 step 4, phase 1, Engram#2523), so the
  flag equals the markers before listings read it
  (`Engram.Folders.Rows.explicit_reads?/0` waits for this ledger).

  Why: until #2639 a cascade deleted a folder's marker without clearing the
  flag on a row it kept (kept for content, or as an ancestor of content, or
  a delete that failed between its marker leg and its rows leg). Such a row
  says explicit with no marker; listed from the flag, it would put a deleted
  empty folder back on users' disks. `FolderTable` only ever sets the flag
  from markers, so between them the flag equals the markers. Well defined
  only while every marker writer still inserts markers (until the phase 2
  write stop, which needs this ledger done).

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`folders` primary-key windows of 200; one fleet walk on the maintenance
  pool on SaaS, per tenant on self-host). Each window is one transaction under
  `SET LOCAL lock_timeout = '2s'` and `statement_timeout = '5s'`: first the
  window's vault rows `FOR SHARE SKIP LOCKED` in their own statement, then
  the marker probe and the update in a later one (see `@lock_vaults_sql` for
  why the order makes a marker being written impossible to miss). A row in a vault held by a writer, or a row a writer
  holds, is skipped and counts as left (the next pass retries it). The
  marker probe is `notes_user_vault_folder_marker`, one index probe a row.
  Steady state is 0 rows: a clean walk writes nothing.

  A row made explicit with no marker on purpose (markers stopped, phase 2,
  `Engram.Folders.MarkerStop`) carries `explicit_seq` and is never touched,
  in this release too: after a rollback E -> D this walk must not clear the
  folders E created (the plugin would trash them).

  Re-verified daily (`reverify?/0`): a 0.89.0 (release C) node serving during
  the rollout to D, or after a rollback and re-roll, deletes markers through
  its cascade without clearing the flag on a row it keeps (content written
  meanwhile, or a delete that stops between its marker leg and its rows
  leg), after this ledger closed. Listed from the flag, that is a ghost
  folder the plugin re-creates. Once the ledger is closed it NEVER reopens:
  a walk repairs such rows in place and reports `:done`, so listings never
  flap back to the markers (after a rollback E -> D those markers do not
  exist). A vault it skipped (a held lock) is logged once a day and retried
  by the next day's walk, as is the rest of a walk its time budget cut (the
  cursor resumes).

  Kill switch: `enabled?/0` is the `explicit_folder_reconcile` service
  override (default on). Off, no pass runs and the ledger stays open, so
  listings keep reading markers.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.Folders.Folder
  alias Engram.Logger.Metadata

  require Logger

  @batch 200
  # Set by a window that left a row unfixed (a skipped lock), for `run_pass/1`.
  @left_key {__MODULE__, :left}

  @impl true
  def name, do: "explicit_folder_reconcile"

  @impl true
  def version, do: 1

  @doc """
  Kill switch: the `explicit_folder_reconcile` service override (default
  on). Off, the runner runs no pass and the ledger stays open.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:explicit_folder_reconcile, true) == true

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size.
  def run_pass(opts) do
    Process.delete(@left_key)

    result =
      IdWindows.heal_pass(name(), Folder, &clear/2, batch_size: Keyword.get(opts, :batch, @batch))

    left = Process.delete(@left_key) || []

    # A closed ledger never reopens (see moduledoc): what it repaired is
    # repaired, and a vault it skipped (a held lock) or a walk its time
    # budget cut is retried by the next day's walk (the cursor resumes).
    if DataMigrations.done?(name(), version()) do
      Enum.each(left, &log_skipped/1)
      :done
    else
      result
    end
  end

  # Once per vault per node per day (`:reconcile_skipped_warned`, 24 h TTL).
  defp log_skipped(vault) do
    Engram.Cache.fetch(:reconcile_skipped_warned, vault, fn ->
      Logger.warning(
        "explicit_folder_reconcile: vault skipped by the re-verify walk, retried tomorrow",
        Metadata.with_category(:warning, :data, vault_id: Ecto.UUID.load!(vault))
      )

      true
    end)
  end

  # A live explicit row of the window that no live marker names. `f` the
  # folder row; the marker probe is `notes_user_vault_folder_marker`.
  @stale """
  f.id = ANY($1) AND f.explicit AND f.explicit_seq IS NULL AND f.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM notes AS n
    WHERE n.user_id = f.user_id AND n.vault_id = f.vault_id AND n.kind = 'folder'
      AND n.deleted_at IS NULL AND n.folder_hmac = f.full_path_hmac)
  """

  # Statement 1: the window's vault rows FOR SHARE SKIP LOCKED. Its own
  # statement on purpose: under READ COMMITTED a statement's snapshot is
  # taken when it starts, so a marker probe in the SAME statement could miss
  # a marker committed after that snapshot but before the lock was reached
  # (`FOR SHARE` follows the update chain; the probe does not), and clear a
  # flag a live marker now names (#2639 re-review, M-A). Every marker writer
  # takes its vault row FOR UPDATE (`Vaults.next_seq!/1`) before it inserts
  # a marker and holds it to commit, so once statement 1 holds a vault row:
  # a writer that committed before it is visible to statement 2's fresh
  # snapshot, a writer still holding the row made SKIP LOCKED skip the vault
  # (its rows count as left), and a writer that starts later waits for this
  # transaction. No interleaving clears the flag of a live marker.
  @lock_vaults_sql """
  SELECT id FROM vaults
  WHERE id IN (SELECT vault_id FROM folders WHERE id = ANY($1))
  FOR SHARE SKIP LOCKED
  """

  # Statement 2, a later snapshot: the stale rows of the locked vaults
  # (`$2`), in a MATERIALIZED CTE evaluated once, then the update.
  @clear_sql """
  WITH c AS MATERIALIZED (
    SELECT f.id FROM folders AS f
    WHERE #{@stale} AND f.vault_id = ANY($2)
    ORDER BY f.id
    FOR NO KEY UPDATE OF f SKIP LOCKED
  )
  UPDATE folders AS f SET explicit = false, updated_at = now()
  FROM c
  WHERE f.id = c.id
  """

  # What is left in a window: the vaults of stale rows a held lock skipped.
  @left_sql "SELECT DISTINCT f.vault_id FROM folders AS f WHERE #{@stale}"

  @doc false
  def lock_vaults_sql, do: @lock_vaults_sql
  @doc false
  def clear_sql, do: @clear_sql
  @doc false
  def left_sql, do: @left_sql

  defp clear(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{rows: locked} = repo.query!(@lock_vaults_sql, [ids])
    %{num_rows: fixed} = repo.query!(@clear_sql, [ids, List.flatten(locked)])
    %{rows: left} = repo.query!(@left_sql, [ids])
    vaults = List.flatten(left)
    if vaults != [], do: Process.put(@left_key, vaults ++ (Process.get(@left_key) || []))
    {fixed, vaults != []}
  end
end
