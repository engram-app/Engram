# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.FoldersExplicitSeqExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  phase/expand. `folders.explicit_seq`: the vault seq at which a folder was
  last made explicit with no marker row (S6 step 4, phase 2, Engram#2523,
  `Engram.Folders.MarkerStop`). A folder delete (phase 2) reads the vault seq before
  its scan and keeps a row made explicit after it
  (`Engram.Folders.Rows.soft_delete/5`): the delete's legs commit in their
  own transactions, so a folder created inside the doomed one meanwhile must
  not be deleted with it. A live marker row did that job (#2466 review, H2).
  `ExplicitFolderReconcile` never clears a row that carries it. Shipped in
  release D (#2639, not with the phase 2 writer that first sets it), so that
  after a rollback E -> D, D's daily reconcile walk already skips every
  folder E made explicit without a marker.

  Additive, nullable, no default: catalog-only, no rewrite. The previous
  release ignores it. `folders` is written on every note write, so the ALTER
  takes its ACCESS EXCLUSIVE lock through `LockTimeoutRetry` (a short
  `lock_timeout`, retried) instead of queueing behind a long writer.
  """

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE folders ADD COLUMN IF NOT EXISTS explicit_seq bigint"
    ])
  end

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE folders DROP COLUMN IF EXISTS explicit_seq"
    ])
  end
end
