# Shared with 20261111000000; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddNameTermsStampExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

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

  Each ALTER takes ACCESS EXCLUSIVE on its table for a catalog change only.
  They run through `LockTimeoutRetry` (lock_timeout_retry.exs): a 5 s
  `lock_timeout` per statement and a statement that hits it (55P03) retried
  twice, so a busy `notes` table does not crash boot. No DDL transaction, so
  each ALTER commits alone and the two tables are never locked together.
  Rerun-safe (`IF NOT EXISTS`). Calls no app module (N-1 gate).
  """

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @doc false
  # Public for `AddNameTermsStampLockTest`.
  def run_up(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      "ALTER TABLE notes ADD COLUMN IF NOT EXISTS name_terms_stamp bytea",
      "ALTER TABLE folders ADD COLUMN IF NOT EXISTS name_terms_stamp bytea"
    ])
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(repo, [
      "ALTER TABLE folders DROP COLUMN IF EXISTS name_terms_stamp",
      "ALTER TABLE notes DROP COLUMN IF EXISTS name_terms_stamp"
    ])
  end
end
