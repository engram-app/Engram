defmodule Engram.Repo.Migrations.T32FlushLegacyObanArgs do
  use Ecto.Migration

  @moduledoc """
  T3.2 / H3 — flush in-flight Oban jobs whose args still carry plaintext
  `path` / `old_path` keys. After this PR's worker rename, those args are
  unreadable by the new perform clause, and the legacy keys themselves
  are exactly the leak we are closing — leaving them in `oban_jobs.args`
  defeats Phase B at-rest encryption for the retention window.

  Targets ONLY pending / scheduled jobs in the two affected workers:
    - `Engram.Workers.DeleteNoteIndex` with arg key `path`
    - `Engram.Workers.EmbedNote`       with arg key `old_path`

  Completed and discarded jobs are left untouched — they are tombstoned
  by Oban's pruner on the existing retention schedule.
  """

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE state IN ('available', 'scheduled', 'retryable')
      AND (
        (worker = 'Engram.Workers.DeleteNoteIndex' AND args ? 'path')
        OR
        (worker = 'Engram.Workers.EmbedNote' AND args ? 'old_path')
      )
    """)
  end

  def down do
    # Irreversible — the deleted jobs cannot be re-enqueued from the new
    # producer signatures because we no longer have the plaintext args.
    :ok
  end
end
