defmodule Engram.Repo.Migrations.IndexNotesEmbedBudgetParkedExpand do
  use Ecto.Migration

  # phase/expand: new index only, no schema change.
  #
  # `ReconcileEmbeddings` lists the users with budget-parked notes on every
  # 5 minute tick (`SELECT DISTINCT user_id ... WHERE embed_budget_parked`).
  # Unindexed that scans `notes`; partial on the flag, so only the parked
  # notes (a small, short-lived set) are indexed.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:notes, [:user_id],
             name: :notes_embed_budget_parked_user_id_index,
             where: "embed_budget_parked AND kind = 'note'",
             concurrently: true
           )
  end
end
