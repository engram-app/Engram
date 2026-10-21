defmodule Engram.Repo.Migrations.AddEmbedBudgetNextToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  `embed_budget_next`: a budget-parked note's next deferred chunk, as a token
  estimate. ReconcileEmbeddings wakes the oldest parked note on the leftover
  balance only once that balance covers this chunk, so it never runs a pass
  that embeds nothing. Nullable, no backfill: NULL reads as 512 tokens.
  """

  def change do
    # Fail fast instead of queueing ACCESS EXCLUSIVE behind a long transaction:
    # the migrator session drops the app's lock_timeout (Release.migrator_config),
    # and a queued ADD COLUMN blocks every read and write of the table behind it.
    # SET LOCAL ends with this migration's transaction; a failed boot retries.
    execute "SET LOCAL lock_timeout = '5s'", "SET LOCAL lock_timeout = '5s'"

    alter table(:notes) do
      add :embed_budget_next, :bigint
    end
  end
end
