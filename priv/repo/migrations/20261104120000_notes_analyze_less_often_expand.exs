defmodule Engram.Repo.Migrations.NotesAnalyzeLessOftenExpand do
  use Ecto.Migration

  @moduledoc """
  phase/expand: `notes` is auto-analyzed at 5% + 1,000 changed rows instead
  of 2% + 1,000 (20261102120000). The 1,000-entry statistics target on
  `user_id` / `vault_id` stays. No schema change.

  With that target every ANALYZE samples up to 300k rows, which reads the
  whole ~257 MB heap. At 2% it ran about 8 times a day on prod; at 5% about
  3.

  `ALTER TABLE ... SET (autovacuum_*)` takes SHARE UPDATE EXCLUSIVE: it
  blocks neither reads nor writes, only VACUUM/ANALYZE/index builds on the
  table (an autovacuum holding it is cancelled). Rerun-safe.
  """

  def up do
    # 0.05: first-sync vaults over ~8k notes still get same-day stats; 0.02 cost ~8 full-heap ANALYZEs/day on 4 GB RDS (swap spike 2026-11-04 23:22Z)
    execute "ALTER TABLE notes SET (autovacuum_analyze_scale_factor = 0.05, " <>
              "autovacuum_analyze_threshold = 1000)"
  end

  def down do
    execute "ALTER TABLE notes SET (autovacuum_analyze_scale_factor = 0.02, " <>
              "autovacuum_analyze_threshold = 1000)"
  end
end
