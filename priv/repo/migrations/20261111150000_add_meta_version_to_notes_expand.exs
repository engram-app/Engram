# Shared with 20261111000000; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddMetaVersionToNotesExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{LockTimeoutRetry, MigrationLog}

  # squawk-ignore: prefer-bigint-over-int
  #
  # A rule version bumped by hand when the title/tags/link derivation
  # changes: it never nears 2^31.

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  The derivation rules (`Engram.Notes.Helpers.meta_version/0`) a note's
  stored title, tags and outgoing links were last checked under, so a rule
  change heals existing notes with no operator step
  (`Engram.DataMigrations.NoteMeta`).

  Nullable, no default: catalog-only, no table rewrite. Not backfilled: NULL
  means "never checked", which the migration's walk checks once. Unindexed,
  so the walk's stamp write can stay heap-only and no save path pays for it.
  No tenant-table DML, so none of the FORCE RLS handling. Calls no app module
  (N-1 gate).

  The ALTER takes ACCESS EXCLUSIVE on `notes` for a catalog change only. It
  runs through `LockTimeoutRetry` (lock_timeout_retry.exs), as
  20261111030000 does: a 5 s `lock_timeout` and a statement that hits it
  (55P03) retried twice, so a long transaction on `notes` at deploy time
  neither queues every notes read and write behind the ALTER nor crashes
  boot. No DDL transaction. Rerun-safe (`IF NOT EXISTS`).
  """

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @doc false
  # Public for `AddMetaVersionLockTest`.
  def run_up(repo) do
    started = MigrationLog.now()

    :ok =
      LockTimeoutRetry.with_lock_timeout(repo, [
        "ALTER TABLE notes ADD COLUMN IF NOT EXISTS meta_version integer"
      ])

    present = MigrationLog.columns(repo, [{"notes", "meta_version"}])
    MigrationLog.done("add_meta_version", [columns_present: "#{present}/1"], started)
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      "ALTER TABLE notes DROP COLUMN IF EXISTS meta_version"
    ])
  end
end
