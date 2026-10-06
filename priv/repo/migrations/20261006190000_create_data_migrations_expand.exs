defmodule Engram.Repo.Migrations.CreateDataMigrationsExpand do
  use Ecto.Migration

  # phase/expand: completion ledger for self-healing data migrations (#1872).
  # One row per migration name. Global: no user_id, so no RLS
  # (test/engram/rls_coverage_test.exs only covers tables with user_id).
  # :timestamptz per Squawk's prefer-timestamp-tz.
  def change do
    create table(:data_migrations, primary_key: false) do
      add :name, :text, primary_key: true
      add :version, :bigint, null: false
      add :completed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON data_migrations TO engram_app",
      "REVOKE ALL ON data_migrations FROM engram_app"
    )
  end
end
