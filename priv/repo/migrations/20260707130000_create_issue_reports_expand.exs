defmodule Engram.Repo.Migrations.CreateIssueReportsExpand do
  use Ecto.Migration

  # phase/expand — new table; no backfill.
  #
  # No RLS (rls_coverage allowlist): reports are founder-triage data. user_id is
  # stamped server-side on insert, there is no per-user read path, and triage
  # reads across all tenants. See @no_rls_allowlist in rls_coverage_test.
  def change do
    create table(:issue_reports, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, :string
      add :surface, :string, null: false
      add :app_version, :string
      add :device_fingerprint, :string
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:issue_reports, [:user_id])
    create index(:issue_reports, [:status, :inserted_at])

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON issue_reports TO engram_app",
      "REVOKE ALL ON issue_reports FROM engram_app"
    )
  end
end
