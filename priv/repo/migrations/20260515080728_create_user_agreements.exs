defmodule Engram.Repo.Migrations.CreateUserAgreements do
  use Ecto.Migration

  def up do
    create table(:user_agreements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document, :text, null: false
      add :version, :text, null: false
      add :accepted_at, :utc_datetime, null: false, default: fragment("now()")
      add :ip_address, :inet
      add :user_agent, :text
    end

    create index(:user_agreements, [:user_id, :document, :accepted_at])

    execute "ALTER TABLE user_agreements ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE user_agreements FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_user_agreements ON user_agreements
      USING (user_id::text = current_setting('app.current_tenant', true))
      WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
    """

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON user_agreements TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE user_agreements_id_seq TO engram_app"
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation_user_agreements ON user_agreements"
    execute "ALTER TABLE user_agreements DISABLE ROW LEVEL SECURITY"
    drop table(:user_agreements)
  end
end
