defmodule Engram.Repo.Migrations.CreateOnboardingActions do
  use Ecto.Migration

  # NOTE: spec/plan literal SQL uses uuid PK + uuid user_id + RLS `::uuid` cast.
  # That is wrong for this repo — `users.id` is bigint (bigserial) and every
  # existing per-user table (notes, vaults, user_agreements, password_reset_tokens,
  # …) uses bigserial PK + bigint user_id FK + `user_id::text = current_setting(...)`
  # RLS. CLAUDE/plan instructions say to follow established style if the spec
  # literal deviates, so this migration matches the existing repo-wide pattern.
  def change do
    create table(:onboarding_actions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
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
        USING (user_id::text = current_setting('app.current_tenant', true))
        WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_onboarding_actions ON onboarding_actions"
    )

    # Grant runtime role same access pattern as vaults/notes.
    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON onboarding_actions TO engram_app",
      "REVOKE ALL ON onboarding_actions FROM engram_app"
    )

    execute(
      "GRANT USAGE, SELECT ON SEQUENCE onboarding_actions_id_seq TO engram_app",
      "REVOKE USAGE, SELECT ON SEQUENCE onboarding_actions_id_seq FROM engram_app"
    )
  end
end
