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

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R9 schema prep: `notes.folder_hmac` becomes nullable so a later release can
  stop writing it on notes (a note's folder is its `folder_ref_id`).
  20261107130100 moves the marker requirement into the kind-shape check and
  makes `notes_set_folder_ref()` keep a hashless note's reference. Calls no
  app module (N-1 gate).

  No DDL transaction, as a lock timeout would abort one and leave nothing to
  retry in. One pinned connection, so the `lock_timeout` reaches the statement
  and is reset after. Rerun-safe.
  """

  @timeout_ms 120_000
  @lock_retries 2

  def up, do: drop_not_null(repo())

  @doc false
  # Public for `NoteFolderHashPrepTimeoutTest`.
  def drop_not_null(repo) do
    repo.checkout(
      fn ->
        repo.query!("SET lock_timeout = '5s'")

        try do
          run(repo, @lock_retries)
        after
          repo.query!("RESET lock_timeout")
        end
      end,
      timeout: @timeout_ms
    )
  end

  # Stays nullable: SET NOT NULL would fail on a note a later release wrote
  # without a hash, and the column being nullable changes nothing for a
  # writer that always sets it.
  def down, do: :ok

  defp run(repo, retries) do
    repo.query!("ALTER TABLE notes ALTER COLUMN folder_hmac DROP NOT NULL", [],
      timeout: @timeout_ms
    )

    :ok
  rescue
    e in Postgrex.Error ->
      if retries > 0 and match?(%{postgres: %{code: :lock_not_available}}, e),
        do: run(repo, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
