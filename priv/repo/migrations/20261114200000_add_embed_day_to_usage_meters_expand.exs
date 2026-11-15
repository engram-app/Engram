Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddEmbedDayToUsageMetersExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  phase/expand. State for the per-user daily embed token ceiling
  (`Engram.EmbedCeiling`, `Engram.UsageMeters.day_take/4`): the UTC day the
  counter belongs to and the tokens spent on it.

  Expand only. ADD COLUMN with no default is catalog-only, so no row is
  rewritten. A NULL day reads as "nothing spent today": a meter row from
  before this migration starts the day at zero, which is also what a new day
  does. No backfill. `usage_meters` has no RLS (one row per user, keyed on
  `user_id`), so there is no tenant trap here.

  `usage_meters` is written on every embed pass, so the brief ACCESS
  EXCLUSIVE lock goes through `LockTimeoutRetry`: a 5 s lock_timeout, the
  statement retried on 55P03, so a busy table cannot crash boot. Both
  statements are rerun-safe (`IF NOT EXISTS`).
  """

  def up do
    LockTimeoutRetry.with_lock_timeout(repo(), [
      "ALTER TABLE usage_meters ADD COLUMN IF NOT EXISTS embed_day date",
      "ALTER TABLE usage_meters ADD COLUMN IF NOT EXISTS embed_day_tokens bigint"
    ])
  end

  def down do
    alter table(:usage_meters) do
      remove_if_exists :embed_day_tokens, :bigint
      remove_if_exists :embed_day, :date
    end
  end
end
