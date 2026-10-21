defmodule Engram.Repo.Migrations.CarryOverEmbedBucket do
  use Ecto.Migration

  @moduledoc """
  Starting balance for every existing meter row when the 20M lifetime cap
  becomes the refilling 6M bucket: what was left of the lifetime allowance,
  capped at the bucket, `min(6M, max(0, 20M - lifetime_embed_tokens))`. A user
  already over 20M starts at 0 and refills with time. Rows created after this
  run have no bucket yet, which reads as full: a new user starts with 6M.

  One UPDATE over `usage_meters` (one row per user that ever embedded; not a
  tenant table, so no FORCE RLS handling). Only NULL buckets, so a re-run, or
  a self-hoster skipping releases, never overwrites a bucket already in use.
  """

  @sql """
  UPDATE usage_meters
     SET embed_bucket_tokens = LEAST(6000000, GREATEST(0, 20000000 - lifetime_embed_tokens)),
         embed_bucket_at = now()
   WHERE embed_bucket_tokens IS NULL
  """

  @doc false
  def sql, do: @sql

  def up, do: execute(@sql)

  # Nothing to undo: the columns' own migration drops them.
  def down, do: :ok
end
