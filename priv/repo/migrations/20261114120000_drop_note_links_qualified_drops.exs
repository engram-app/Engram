# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("bounded_index_build.exs", __DIR__)

defmodule Engram.Repo.Migrations.DropNoteLinksQualifiedDrops do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, LockTimeoutRetry}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Drops `note_links.qualified` and `note_links_qualified`, added by
  20261114000200 (Gap B, PR 2592). The S5 gate derives "qualified link" from
  the stored keys instead (`Engram.Links.qualified_links_query/4`).

  One release is safe: 20261114000200 never shipped in a release (prod runs
  be40408, which lacks it), so no released node reads or writes the column.
  Prod and a self-hoster apply the add and this drop in one batch; staging,
  which ran the add, drops what it has; a fresh database has nothing to drop.
  IF EXISTS covers every case.

  The index goes first, CONCURRENTLY (SHARE UPDATE EXCLUSIVE: writes keep
  running), so the column drop does not take it under ACCESS EXCLUSIVE. DROP
  COLUMN is then a catalog change, no rewrite, held for milliseconds. Both
  run under LockTimeoutRetry's 5 s `lock_timeout`, retried twice, so a long
  transaction fails the statement fast instead of queueing every link read.

  `down` restores the empty nullable column and its partial index (empty: no
  row is `qualified`), as the expand left them before its backfill. The
  index goes through BoundedIndexBuild like the expand's, so a build that
  times out never leaves an INVALID index behind for IF NOT EXISTS to skip.
  """

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "DROP INDEX CONCURRENTLY IF EXISTS note_links_qualified",
      "ALTER TABLE note_links DROP COLUMN IF EXISTS qualified"
    ])
  end

  def down do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE note_links ADD COLUMN IF NOT EXISTS qualified boolean"
    ])

    BoundedIndexBuild.build!(
      repo(),
      [
        {"note_links_qualified",
         "ON note_links (user_id, vault_id, target_basename_hmac) WHERE qualified"}
      ],
      lock_key: 20_261_114_120_000,
      label: "drop_note_links_qualified_down"
    )
  end
end
