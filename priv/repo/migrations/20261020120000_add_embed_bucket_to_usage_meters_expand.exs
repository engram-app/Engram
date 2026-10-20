defmodule Engram.Repo.Migrations.AddEmbedBucketToUsageMetersExpand do
  use Ecto.Migration

  @moduledoc """
  State for Free's refilling embed-token bucket (`Engram.UsageMeters.bucket_take/4`),
  which replaces the 20M lifetime cap.

  Expand-only, not backfilled: a NULL bucket reads as FULL, so every existing
  user (Free or paid) starts with the whole allowance on deploy with no DML.
  Full rather than carrying over `20M - lifetime_embed_tokens`: the carry-over
  would hand the users who tried the product hardest (several sit at or over
  the old cap) an empty bucket on day one, which is the silent stop this change
  exists to remove. The cost of the generous choice is bounded and one-off: at
  most 6M tokens per existing Free account.

  `double precision`, not bigint: refill is ~0.19 tokens per second, so an
  integer bucket that re-stamps its clock on every take would floor that away
  and never refill under a steady trickle of small takes. Same reason the old
  `usage_buckets.tokens` column was a float.
  """

  def up do
    alter table(:usage_meters) do
      add :embed_bucket_tokens, :float
      add :embed_bucket_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:usage_meters) do
      remove :embed_bucket_tokens
      remove :embed_bucket_at
    end
  end
end
