defmodule Engram.Repo.Migrations.IndexNoteBodiesUserNote do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R5 delta reads: `note_bodies` had only its primary key, and under RLS its
  one filter is `user_id`, so the manifest's body join (`NoteBody.join/1`)
  hash-joined a seq scan of every tenant's bodies (106 ms on a 10k-note
  staging vault, growing with the whole table, not the vault). The join now
  also matches `user_id`; this index serves it: an index scan on the
  owner, then a heap fetch for `crdt_head`.

  Keys only, never a body column (`crdt_head` included, even as INCLUDE):
  a checkpoint rewrites `content_ct` / `crdt_ct` / `crdt_head`, and an
  indexed column there would end the table's HOT updates (fillfactor 75,
  pkey only, 20261021110100). `user_id` and `note_id` never change.

  Additive: code without it is correct, only slower, so a skip-release
  install and the previous release are both safe. Dropped by name first, so
  a retry after a failed CONCURRENTLY build rebuilds an INVALID index
  instead of skipping it.
  """

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_note"

    execute """
    CREATE INDEX CONCURRENTLY note_bodies_user_note
      ON note_bodies (user_id, note_id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_bodies_user_note"
  end
end
