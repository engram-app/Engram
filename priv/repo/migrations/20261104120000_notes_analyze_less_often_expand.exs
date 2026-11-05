defmodule Engram.Repo.Migrations.NotesAnalyzeLessOftenExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand: `notes` is auto-analyzed at 20% + 1,000 changed rows instead
  of 2% + 1,000 (20261102120000). No schema change.

  Prod 2026-11-04/05: with `SET STATISTICS 1000` on `user_id` / `vault_id`
  every ANALYZE samples up to 300k rows, which reads the whole ~257 MB heap.
  At 2% it ran about 8 times a day, cold, and the 23:22Z run drove a swap
  spike on the 4 GB RDS box. At 20% (~99k changed rows on ~490k rows,
  against ~87k changes a day) it runs about once a day.

  Cost: a new vault reaches the most-common-values list later (up to ~1 day
  of writes instead of a few thousand), so a big vault's FIRST sync can plan
  key lookups on a 1-row estimate for longer (prod E1a,
  `Engram.NotesGenericPlanTest`). The 1,000-entry statistics target stays.

  `ALTER TABLE ... SET (autovacuum_*)` takes SHARE UPDATE EXCLUSIVE: it
  blocks neither reads nor writes, only VACUUM/ANALYZE/index builds on the
  table (an autovacuum holding it is cancelled). Rerun-safe.
  """

  def up do
    execute "ALTER TABLE notes SET (autovacuum_analyze_scale_factor = 0.2, " <>
              "autovacuum_analyze_threshold = 1000)"
  end

  def down do
    execute "ALTER TABLE notes SET (autovacuum_analyze_scale_factor = 0.02, " <>
              "autovacuum_analyze_threshold = 1000)"
  end
end
