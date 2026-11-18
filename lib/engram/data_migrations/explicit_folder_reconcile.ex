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
  pool on SaaS, per tenant on self-host). Each window is one statement under
  `SET LOCAL lock_timeout = '2s'` and `statement_timeout = '5s'`. It first
  takes the window's vault rows `FOR SHARE SKIP LOCKED`: every marker writer
  takes its vault row (the seq lock) before it inserts a marker and sets the
  flag, so a marker that is being written is never missed and its flag never
  cleared after it. A row in a vault held by a writer, or a row a writer
  holds, is skipped and counts as left (the next pass retries it). The
  marker probe is `notes_user_vault_folder_marker`, one index probe a row.
  Steady state is 0 rows: a clean walk writes nothing.

  Kill switch: `enabled?/0` is the `explicit_folder_reconcile` service
  override (default on). Off, no pass runs and the ledger stays open, so
  listings keep reading markers.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Folders.Folder

  @batch 200

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
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` overrides the window size.
  def run_pass(opts) do
    IdWindows.heal_pass(name(), Folder, &clear/2, batch_size: Keyword.get(opts, :batch, @batch))
  end

  # A live explicit row of the window that no live marker names. `f` the
  # folder row; the marker probe is `notes_user_vault_folder_marker`.
  @stale """
  f.id = ANY($1) AND f.explicit AND f.deleted_at IS NULL AND NOT EXISTS (
    SELECT 1 FROM notes AS n
    WHERE n.user_id = f.user_id AND n.vault_id = f.vault_id AND n.kind = 'folder'
      AND n.deleted_at IS NULL AND n.folder_hmac = f.full_path_hmac)
  """

  # The window's vault rows FOR SHARE (a marker writer holds its vault row
  # FOR UPDATE through its write, see the moduledoc), then its stale rows,
  # each in a MATERIALIZED CTE evaluated once, then the update.
  @clear_sql """
  WITH v AS MATERIALIZED (
    SELECT id FROM vaults
    WHERE id IN (SELECT vault_id FROM folders WHERE id = ANY($1))
    FOR SHARE SKIP LOCKED
  ), c AS MATERIALIZED (
    SELECT f.id FROM folders AS f
    WHERE #{@stale} AND f.vault_id IN (SELECT id FROM v)
    ORDER BY f.id
    FOR NO KEY UPDATE OF f SKIP LOCKED
  )
  UPDATE folders AS f SET explicit = false, updated_at = now()
  FROM c
  WHERE f.id = c.id
  """

  # What is left in a window: a stale row a held lock skipped.
  @left_sql "SELECT count(*)::int FROM folders AS f WHERE #{@stale}"

  @doc false
  def clear_sql, do: @clear_sql

  defp clear(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{num_rows: fixed} = repo.query!(@clear_sql, [ids])
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    {fixed, left > 0}
  end
end
