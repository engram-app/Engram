defmodule Engram.Repo.Migrations.AddNameTermsStampExpand do
  use Ecto.Migration

  @moduledoc """
  `name_terms_stamp` on `notes` and `folders`: the version stamp of a ref's
  `name_terms` rows (`Engram.Search.NameTerms`). A writer sets it to
  `<<version>> || basename_hmac` (notes) or `<<version>> || name_hmac`
  (folders), the key of the name its terms were computed from. A writer that
  renames without rewriting the terms (the previous release) leaves the
  stamp behind the hmac, which the next migration's partial indexes find.
  A folder rename leaves its child notes' basenames, and so their stamps,
  alone.

  Nullable, no default: a catalog-only change. NULL is "never written", which
  is stale, so the column is not backfilled here (the `NameTerms` ledger is).
  """

  def up do
    execute "SET lock_timeout = '5s'"
    execute "ALTER TABLE notes ADD COLUMN IF NOT EXISTS name_terms_stamp bytea"
    execute "ALTER TABLE folders ADD COLUMN IF NOT EXISTS name_terms_stamp bytea"
    execute "RESET lock_timeout"
  end

  def down do
    execute "ALTER TABLE folders DROP COLUMN IF EXISTS name_terms_stamp"
    execute "ALTER TABLE notes DROP COLUMN IF EXISTS name_terms_stamp"
  end
end
