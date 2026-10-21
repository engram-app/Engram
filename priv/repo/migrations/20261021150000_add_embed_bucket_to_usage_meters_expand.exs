defmodule Engram.Repo.Migrations.AddEmbedBucketToUsageMetersExpand do
  use Ecto.Migration

  @moduledoc """
  State for Free's refilling embed-token bucket (`Engram.UsageMeters.bucket_take/4`),
  which replaces the 20M lifetime cap.

  Expand-only. Existing rows are given their starting balance by
  `20261020130001_carry_over_embed_bucket.exs` (what was left of the lifetime
  allowance, capped at the bucket). A NULL bucket reads as FULL, so a meter
  row created after that, a new user, starts with the whole 6M.

  `double precision`, not bigint: refill is ~0.19 tokens per second, so an
  integer bucket that re-stamps its clock on every take would floor that away
  and never refill under a steady trickle of small takes. Same reason the old
  `usage_buckets.tokens` column was a float.
  """

  def up do
    # Fail fast instead of queueing ACCESS EXCLUSIVE behind a long transaction:
    # the migrator session drops the app's lock_timeout (Release.migrator_config),
    # and a queued ADD COLUMN blocks every read and write of the table behind it.
    # SET LOCAL ends with this migration's transaction; a failed boot retries.
    execute "SET LOCAL lock_timeout = '5s'"

    alter table(:usage_meters) do
      add :embed_bucket_tokens, :float
      add :embed_bucket_at, :timestamptz
    end
  end

  def down do
    alter table(:usage_meters) do
      remove :embed_bucket_tokens
      remove :embed_bucket_at
    end
  end
end
