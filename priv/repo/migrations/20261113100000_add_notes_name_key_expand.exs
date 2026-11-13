# Shared helpers; see each file for why they are not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)
Code.require_file("bounded_index_build.exs", __DIR__)
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddNotesNameKeyExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.{BoundedIndexBuild, LockTimeoutRetry, MigrationLog}

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes.name_key`: a live note's folder row plus its casefolded name, as one
  stored `bytea` (`name_ci_hmac || uuid_send(folder_ref_id)`), for the S3
  by-path lookup in a vault holding a folder moved without a cascade
  (`Engram.Notes.Location`, O(1) folder rename plan, Engram#2523).

  Why a stored column: 20261112100000's `notes_folder_name_live` indexes
  that concatenation as an expression, and a query can use it only by
  naming the same expression, which applies `byteacat` and `uuid_send` to
  columns. Neither is leakproof, so under FORCE RLS (prod's `engram_app`)
  Postgres evaluates such a qual only after the policy's own quals: it never
  drives an index, and the lookup read the tenant's whole vault on
  `notes_user_vault_live` (staging 2026-11-13: 1,341 buffers on 1,530 notes
  against 4 on 0.83.0). A plain column compared to a bound value is
  leakproof. See docs/context/rls-leakproof-index-quals.md.

  `notes_set_name_key` (BEFORE INSERT OR UPDATE OF the five inputs and
  `deleted_at`) keeps it
  for every writer, this release, the previous release's nodes and raw SQL:
  the key while the row is a note with a folder row and current name keys
  (`name_stamp = path_nonce || '\\x01'`, `Engram.Crypto.NameKeys.stamp/1`;
  the version byte is inlined, so a bump of `NameKeys.version/0` ships a
  new trigger, `NameKeyTriggerTest` fails until then), else NULL. So a stale
  name never matches by name. It only assigns `NEW` and fires on a
  statement that lists one of its inputs, which `name_key` is not: it
  cannot loop. `deleted_at` is listed because `notes_folder_ref_live_only`
  (same column) blanks `folder_ref_id` on a restore into a trashed folder
  row, and a trigger's own change does not fire another's `UPDATE OF`. Row
  triggers of one timing fire in name order, so that one runs first and
  this one sees the blanked ref. Cost: one plpgsql call per insert, and per
  update that names an input (create, rename, move, name backfill, folder
  release, delete, restore); a content save names none.

  `notes_name_key_live (vault_id, name_key)` serves that lookup, partial on
  live keyed rows. No other query names `name_key`, so no other read can
  pick it (the tie and skip-scan traps 20261112100000 documents).

  Expand only: the previous release ignores the column, the trigger and the
  index. No data walk at boot: ADD COLUMN with no default is catalog-only,
  and rows written before this release keep a NULL key until a writer
  touches an input. The lookup reads names only in a vault holding a folder
  moved without a cascade, which nothing writes before S5, so S5 backfills
  the key for every row before its first such write. The index build reads
  the heap (CONCURRENTLY, two passes) and holds only the new rows' entries.
  """

  def up do
    started = MigrationLog.now()

    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE notes ADD COLUMN IF NOT EXISTS name_key bytea",
      """
      CREATE OR REPLACE FUNCTION notes_set_name_key() RETURNS trigger
      LANGUAGE plpgsql SET search_path = '' AS $$
      BEGIN
        NEW.name_key := CASE
          WHEN NEW.kind = 'note' AND NEW.folder_ref_id IS NOT NULL
               AND NEW.name_ci_hmac IS NOT NULL
               AND NEW.name_stamp = NEW.path_nonce || '\\x01'::bytea
          THEN NEW.name_ci_hmac || uuid_send(NEW.folder_ref_id)
        END;
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE OR REPLACE TRIGGER notes_set_name_key
        BEFORE INSERT OR UPDATE OF kind, folder_ref_id, name_ci_hmac, name_stamp, path_nonce, deleted_at
        ON notes
        FOR EACH ROW EXECUTE FUNCTION notes_set_name_key()
      """
    ])

    BoundedIndexBuild.build!(
      repo(),
      [
        {"notes_name_key_live",
         "ON notes (vault_id, name_key) WHERE name_key IS NOT NULL AND deleted_at IS NULL"}
      ],
      lock_key: 20_261_113_100_000,
      label: "add_notes_name_key"
    )

    MigrationLog.indexes(repo(), "add_notes_name_key", ["notes_name_key_live"], started)
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_name_key_live"
    execute "DROP TRIGGER IF EXISTS notes_set_name_key ON notes"
    execute "DROP FUNCTION IF EXISTS notes_set_name_key()"
    alter table(:notes), do: remove_if_exists(:name_key, :binary)
  end
end
