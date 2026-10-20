defmodule Engram.Repo.Migrations.ExpandNotesCoreKeys do
  use Ecto.Migration

  @moduledoc """
  Wave 3, expand step (`docs/context/notes-chunks-hyperopt.md` 2.1, 6): the
  narrow core columns `notes` moves to, beside the ones they replace.

    * `path_id`, `folder_id`, `basename_id`, `path_ci_id`, `type_id`, `tag_ids`:
      the first 16 bytes of each HMAC as a uuid (fixed width, no varlena
      header), byte-identical to v5's `FilterId.from_hmac`. A unique
      `(vault_id, path_id)` needs no collision inside one vault; at 10k paths
      the birthday odds are about 2^-101.
    * `is_folder` for `kind`, `key_version` (int2) for `dek_version`,
      `path_len` (int2) for `path_length`, `parse_code` (int2) for
      `parse_status`, `link_keys_v` (int2) for `link_keys_stamp`,
      `content_digest` (bytea) for the hex `content_hash`.

  All nullable with no default: metadata-only, no rewrite. They are filled by
  the `notes_derive_core_keys` trigger (next migration) on every write, and
  for existing rows by the `NoteSplit` data migration. Nothing reads them
  until that ledger is done. The old columns go in a later release.

  12 attributes: notes has 55, and a heap tuple's header grows 8 bytes past
  72 (dropped columns keep counting until a rewrite), so the budget is tight
  on purpose.

  fillfactor 90: checkpoints change `seq` and are non-HOT by design, and 42%
  of notes updates moved to a new page in prod; the slack keeps the new
  version on its page. Applies to pages written from now on.
  """

  def up do
    execute "SET lock_timeout = '5s'"

    # The int2 columns hold bounded codes (a DEK version, a path length under
    # PATH_MAX, an enum, a Unicode version), never a counter, so the 16-bit
    # overflow squawk warns about cannot happen; the 2 bytes each are the point.
    # One line: squawk's ignore comment covers the line after it.
    execute "-- squawk-ignore prefer-bigint-over-smallint\n" <>
              "ALTER TABLE notes ADD COLUMN path_id uuid, ADD COLUMN folder_id uuid, " <>
              "ADD COLUMN basename_id uuid, ADD COLUMN path_ci_id uuid, ADD COLUMN type_id uuid, " <>
              "ADD COLUMN tag_ids uuid[], ADD COLUMN is_folder boolean, " <>
              "ADD COLUMN key_version smallint, ADD COLUMN path_len smallint, " <>
              "ADD COLUMN parse_code smallint, ADD COLUMN link_keys_v smallint, " <>
              "ADD COLUMN content_digest bytea"

    execute "ALTER TABLE notes SET (fillfactor = 90)"
    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE notes RESET (fillfactor)"

    alter table(:notes) do
      remove :content_digest
      remove :link_keys_v
      remove :parse_code
      remove :path_len
      remove :key_version
      remove :is_folder
      remove :tag_ids
      remove :type_id
      remove :path_ci_id
      remove :basename_id
      remove :folder_id
      remove :path_id
    end
  end
end
