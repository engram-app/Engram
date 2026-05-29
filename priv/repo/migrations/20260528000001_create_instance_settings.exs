defmodule Engram.Repo.Migrations.CreateInstanceSettings do
  use Ecto.Migration

  def change do
    create table(:instance_settings) do
      add :registration_mode, :string, null: false, default: "invite_only"
      timestamps(type: :utc_datetime)
    end

    # Singleton guard: only id=1 may ever exist.
    create constraint(:instance_settings, :singleton, check: "id = 1")
  end
end
