defmodule Engram.Repo.Migrations.AddBootstrapCompletedAtToInstanceSettings do
  use Ecto.Migration

  # Explicit one-time-window state. Marks when the claim window closed —
  # set exactly once by the first signup. Replaces the implicit
  # "Repo.aggregate(User, :count) == 0" hot-path check on every signup.
  def change do
    alter table(:instance_settings) do
      add :bootstrap_completed_at, :timestamptz
    end
  end
end
