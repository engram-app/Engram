defmodule Engram.Repo.Migrations.AddFreeTierAcceptedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :free_tier_accepted_at, :timestamptz
    end
  end
end
