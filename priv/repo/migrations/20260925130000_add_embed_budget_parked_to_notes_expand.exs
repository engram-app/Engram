defmodule Engram.Repo.Migrations.AddEmbedBudgetParkedToNotesExpand do
  use Ecto.Migration

  # phase/expand — additive nullable column; no backfill (NULL = not parked).
  #
  # Marks an `embed_retry_after` that was set because the user's lifetime
  # embed budget ran out, as opposed to a poison-job cooldown. An upgrade
  # lifts the budget, so ReconcileEmbeddings may skip a budget park for a
  # paying user, but must still honour a poison cooldown (that one re-bills
  # Voyage on every retry).
  def change do
    alter table(:notes) do
      add :embed_budget_parked, :boolean
    end
  end
end
