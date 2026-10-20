defmodule Engram.Repo.Migrations.AddEmbedBudgetNextToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  `embed_budget_next`: a budget-parked note's next deferred chunk, as a token
  estimate. ReconcileEmbeddings wakes the oldest parked note on the leftover
  balance only once that balance covers this chunk, so it never runs a pass
  that embeds nothing. Nullable, no backfill: NULL reads as 512 tokens.
  """

  def change do
    alter table(:notes) do
      add :embed_budget_next, :bigint
    end
  end
end
