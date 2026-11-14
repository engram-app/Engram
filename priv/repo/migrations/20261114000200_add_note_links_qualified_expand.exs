# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddNoteLinksQualifiedExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, LockTimeoutRetry, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  phase/expand. `note_links.qualified`: whether the link names its target by
  path (`[[Folder/Note]]`, `[[../Note]]`, `[x](Folder/Note.md)`), from
  `Engram.Links.qualified?/1` (O(1) folder rename plan S4.6, Engram#2523).

  S5 replaces the folder rename's one `RewriteNoteLinks` job per moved note
  with a gate. `qualified` covers path-WRITTEN links only. A bare `[[Note]]`
  resolves by name and survives a folder move UNLESS the moved note's
  basename collides with another live row (the rewriter then qualifies it,
  `collision?`), so S5's gate is "EXISTS qualified link OR a moved basename
  has more than one live row"; this column serves the first arm.
  `note_links_qualified (user_id, vault_id, target_basename_hmac) WHERE
  qualified` serves that probe (one descent on `(user_id, vault_id)`, the
  RLS qual first like every `note_links` index) and S5's paged job by moved
  basename. Plain column quals only, so FORCE RLS cannot bar it
  (docs/context/rls-leakproof-index-quals.md).

  Expand only: nothing reads the column or the index in this release, and
  0.84.0 ignores both. ADD COLUMN with no default is catalog-only. Every
  row is NULL at build time, so the partial index holds nothing: the build
  is two heap passes of `note_links` (CONCURRENTLY) with no entries to sort.
  Prod estimate: ~1.9M rows / ~0.7 GB heap (staging measured 63,042 links
  over 6,799 notes rows, 23 MB; scaled to prod's ~208k notes rows), seconds
  to tens of seconds inside BoundedIndexBuild's 110 s budget. The
  `NoteLinkQualified` ledger fills existing rows after boot.
  """

  def up do
    started = MigrationLog.now()

    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE note_links ADD COLUMN IF NOT EXISTS qualified boolean"
    ])

    BoundedIndexBuild.build!(
      repo(),
      [
        {"note_links_qualified",
         "ON note_links (user_id, vault_id, target_basename_hmac) WHERE qualified"}
      ],
      lock_key: 20_261_114_000_200,
      label: "add_note_links_qualified"
    )

    MigrationLog.indexes(repo(), "add_note_links_qualified", ["note_links_qualified"], started)
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS note_links_qualified"
    alter table(:note_links), do: remove_if_exists(:qualified, :boolean)
  end
end
