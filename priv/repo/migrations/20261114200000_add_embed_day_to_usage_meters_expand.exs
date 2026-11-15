defmodule Engram.Repo.Migrations.AddEmbedDayToUsageMetersExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand. State for the per-user daily embed token ceiling
  (`Engram.EmbedCeiling`, `Engram.UsageMeters.day_take/4`): the UTC day the
  counter belongs to and the tokens spent on it.

  Expand only. ADD COLUMN with no default is catalog-only, so no row is
  rewritten. A NULL day reads as "nothing spent today": a meter row from
  before this migration starts the day at zero, which is also what a new day
  does. No backfill. `usage_meters` has no RLS (one row per user, keyed on
  `user_id`), so there is no tenant trap here.
  """

  def up do
    # Fail fast instead of queueing ACCESS EXCLUSIVE behind a long transaction,
    # as `20261021150000_add_embed_bucket_to_usage_meters_expand.exs` does.
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:usage_meters) do
      add :embed_day, :date
      add :embed_day_tokens, :bigint
    end
  end

  def down do
    alter table(:usage_meters) do
      remove :embed_day
      remove :embed_day_tokens
    end
  end
end
