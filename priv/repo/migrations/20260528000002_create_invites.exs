defmodule Engram.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  def change do
    create table(:invites) do
      add :token_hash, :string, null: false
      add :created_by, references(:users, on_delete: :delete_all), null: false
      add :label, :string
      add :max_uses, :integer, null: false, default: 1
      add :use_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:token_hash])
    create index(:invites, [:created_by])
  end
end
