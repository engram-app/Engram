# squawk-ignore: ban-drop-not-null
# DROP NOT NULL is metadata-only in Postgres: no table rewrite, no scan, a brief
# ACCESS EXCLUSIVE lock under this migration's lock_timeout (5s). N-1 safe:
# release C (this one) and 0.78 still write folder_hmac on every note, so no
# NULL exists until release D, the first that writes NULL; markers keep the
# hash required by notes_kind_shape_v3_check (20261107130100). The markers are
# per-rule and per-file (no per-statement ignore), so this file holds only
# this one statement.
defmodule Engram.Repo.Migrations.NoteFolderHashDropNotNullExpand do
  use Ecto.Migration

  @moduledoc """
  R9 schema prep: `notes.folder_hmac` becomes nullable so a later release can
  stop writing it on notes (a note's folder is its `folder_ref_id`).
  20261107130100 moves the marker requirement into the kind-shape check and
  makes `notes_set_folder_ref()` keep a hashless note's reference. Calls no
  app module (N-1 gate).
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE notes ALTER COLUMN folder_hmac DROP NOT NULL"
    execute "RESET lock_timeout"
  end

  # Stays nullable: SET NOT NULL would fail on a note a later release wrote
  # without a hash, and the column being nullable changes nothing for a
  # writer that always sets it.
  def down, do: :ok
end
