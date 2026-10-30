defmodule Engram.Repo.Migrations.IndexNoteBodiesUserHead do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R5 delta reads: `note_bodies` had only its primary key, and under RLS its
  one filter is `user_id`, so the manifest's body join (`NoteBody.join/1`)
  hash-joined a seq scan of every tenant's bodies (106 ms on a 10k-note
  staging vault, growing with the whole table, not the vault). The join now
  also matches `user_id`; this index serves it, and carries `note_id` and
  `crdt_head` so the manifest's head read is index-only.

  Additive: code without it is correct, only slower, so a skip-release
  install and the previous release are both safe. Dropped by name first, so
  a retry after a failed CONCURRENTLY build rebuilds an INVALID index
  instead of skipping it.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_head"

    execute """
    CREATE INDEX CONCURRENTLY note_bodies_user_head
      ON note_bodies (user_id) INCLUDE (note_id, crdt_head)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_head"
  end
end
