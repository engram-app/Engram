defmodule Engram.Repo.Migrations.AddEmbedBudgetQueueToNotesExpand do
  use Ecto.Migration

  @moduledoc """
  The Free embed-bucket queue on `notes`: `embed_budget_parked_at` is a parked
  note's FIFO position (kept across re-parks), `embed_budget_need` the tokens
  it still needs. ReconcileEmbeddings wakes the oldest parked notes whose need
  fits the bucket. Expand-only and nullable: a note parked by an older release
  has neither, and re-parks with both on its next pass.
  """

  def up do
    alter table(:notes) do
      add :embed_budget_parked_at, :timestamptz
      add :embed_budget_need, :bigint
    end
  end

  def down do
    alter table(:notes) do
      remove :embed_budget_parked_at
      remove :embed_budget_need
    end
  end
end
