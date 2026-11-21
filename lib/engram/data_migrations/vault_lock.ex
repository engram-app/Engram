defmodule Engram.DataMigrations.VaultLock do
  @moduledoc """
  A data-migration window's vault rows `FOR SHARE SKIP LOCKED`, by primary
  key from a bound array of vault ids (`Engram.DataMigrations.FolderMarkerDelete`,
  `Engram.DataMigrations.ExplicitFolderReconcile`).

  In a statement of its own, before the window's checks and writes: under
  READ COMMITTED each later statement takes its snapshot after the lock, so
  it sees every write committed before the lock (every folder and marker
  writer takes its vault row first, `Vaults.next_seq!/1`). A vault a writer
  holds is skipped; its rows count as left and the next pass retries them.

  By primary key: a maintenance job reads no table whole. As a semi join on
  the window's rows the planner read every vault row.
  """

  @sql "SELECT id, user_id FROM vaults WHERE id = ANY($1::uuid[]) FOR SHARE SKIP LOCKED"

  @doc false
  def sql, do: @sql

  @doc "The locked vaults of `vault_ids` (dumped uuids), as `[id, owner]` rows."
  @spec lock(module(), [binary()]) :: [[binary()]]
  def lock(_repo, []), do: []
  def lock(repo, vault_ids), do: repo.query!(@sql, [vault_ids]).rows
end
