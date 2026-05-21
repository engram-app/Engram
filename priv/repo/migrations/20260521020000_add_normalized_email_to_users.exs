defmodule Engram.Repo.Migrations.AddNormalizedEmailToUsers do
  use Ecto.Migration

  # Pricing v2 §A — multi-account farming defense.
  # Non-unique index in this migration; UNIQUE constraint added in follow-up
  # after a manual dup audit (gmail-alias variants present in prod before this
  # column existed may need reconciliation).
  # No backfill — column populates on next write per row.
  def change do
    alter table(:users) do
      add :normalized_email, :text
    end

    create index(:users, [:normalized_email])
  end
end
