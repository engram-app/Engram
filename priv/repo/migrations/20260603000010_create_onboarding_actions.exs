defmodule Engram.Repo.Migrations.CreateOnboardingActions do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # PG18 + uuidv7 rework (Phase C): users.id is uuid, so onboarding_actions PK is
  # uuid w/ uuidv7() default and user_id is uuid. RLS keeps the existing
  # ::text cast pattern (uuid casts to text fine).
  def change do
    create table(:onboarding_actions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :metadata, :map, default: %{}, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:onboarding_actions, [:user_id, :action])

    # RLS: mirror notes/vaults/user_agreements pattern — tenant scoped by user_id.
    execute(
      "ALTER TABLE onboarding_actions ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE onboarding_actions DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE onboarding_actions FORCE ROW LEVEL SECURITY",
      "ALTER TABLE onboarding_actions NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_onboarding_actions ON onboarding_actions
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_onboarding_actions ON onboarding_actions"
    )

    # Grant runtime role same access pattern as vaults/notes.
    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON onboarding_actions TO engram_app",
      "REVOKE ALL ON onboarding_actions FROM engram_app"
    )
  end
end
