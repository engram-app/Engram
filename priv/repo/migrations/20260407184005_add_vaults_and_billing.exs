defmodule Engram.Repo.Migrations.AddVaultsAndBilling do
  use Ecto.Migration

  def up do
    # ── Plans ──────────────────────────────────────────────────────
    create table(:plans) do
      add :name, :text, null: false
      add :limits, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:plans, [:name])

    # ── User Overrides ─────────────────────────────────────────────
    create table(:user_overrides) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :overrides, :map, null: false, default: %{}
      add :reason, :text
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:user_overrides, [:user_id])

    # ── Add plan_id FK to users ────────────────────────────────────
    alter table(:users) do
      add :plan_id, references(:plans, on_delete: :nothing)
    end

    # ── Vaults ─────────────────────────────────────────────────────
    create table(:vaults) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :description, :text
      add :slug, :text, null: false
      add :client_id, :text
      add :is_default, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    # One default vault per user (partial unique)
    create index(:vaults, [:user_id],
             name: :vaults_user_id_default_index,
             unique: true,
             where: "is_default = true AND deleted_at IS NULL"
           )

    # Unique slug per user among active vaults
    create index(:vaults, [:user_id, :slug],
             name: :vaults_user_id_slug_index,
             unique: true,
             where: "deleted_at IS NULL"
           )

    # Unique client_id per user when set and active
    create index(:vaults, [:user_id, :client_id],
             name: :vaults_user_id_client_id_index,
             unique: true,
             where: "client_id IS NOT NULL AND deleted_at IS NULL"
           )

    # ── API Key Vaults (join table) ────────────────────────────────
    create table(:api_key_vaults, primary_key: false) do
      add :api_key_id, references(:api_keys, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :vault_id, references(:vaults, on_delete: :delete_all), null: false, primary_key: true
    end

    create unique_index(:api_key_vaults, [:api_key_id, :vault_id])

    # ── Add vault_id to notes, chunks, attachments (nullable for backfill) ──
    alter table(:notes) do
      add :vault_id, references(:vaults, on_delete: :delete_all)
    end

    alter table(:chunks) do
      add :vault_id, references(:vaults, on_delete: :delete_all)
    end

    alter table(:attachments) do
      add :vault_id, references(:vaults, on_delete: :delete_all)
    end

    # ── Backfill: create default vault per user with existing data ──
    # For each user who has notes/chunks/attachments, create a default vault
    # and assign all their rows to it.
    execute """
    INSERT INTO vaults (user_id, name, slug, is_default, created_at, updated_at)
    SELECT DISTINCT u.id, 'Default', 'default', true, NOW(), NOW()
    FROM users u
    WHERE EXISTS (SELECT 1 FROM notes n WHERE n.user_id = u.id)
       OR EXISTS (SELECT 1 FROM attachments a WHERE a.user_id = u.id)
    ON CONFLICT DO NOTHING
    """

    execute """
    UPDATE notes SET vault_id = v.id
    FROM vaults v
    WHERE notes.user_id = v.user_id AND v.is_default = true AND notes.vault_id IS NULL
    """

    execute """
    UPDATE chunks SET vault_id = n.vault_id
    FROM notes n
    WHERE chunks.note_id = n.id AND chunks.vault_id IS NULL
    """

    execute """
    UPDATE attachments SET vault_id = v.id
    FROM vaults v
    WHERE attachments.user_id = v.user_id AND v.is_default = true AND attachments.vault_id IS NULL
    """

    # ── Now enforce NOT NULL after backfill ──
    execute "ALTER TABLE notes ALTER COLUMN vault_id SET NOT NULL"
    execute "ALTER TABLE chunks ALTER COLUMN vault_id SET NOT NULL"
    execute "ALTER TABLE attachments ALTER COLUMN vault_id SET NOT NULL"

    # Drop old unique indexes on notes and attachments
    drop index(:notes, [:user_id, :path], name: :notes_user_id_path_index)
    drop index(:attachments, [:user_id, :path], name: :attachments_user_id_path_index)

    # New unique indexes scoped by vault_id
    create index(:notes, [:user_id, :vault_id, :path],
             name: :notes_user_id_vault_id_path_index,
             unique: true,
             where: "deleted_at IS NULL"
           )

    create index(:attachments, [:user_id, :vault_id, :path],
             name: :attachments_user_id_vault_id_path_index,
             unique: true,
             where: "deleted_at IS NULL"
           )

    # Regular vault_id indexes for efficient querying
    create index(:notes, [:vault_id])
    create index(:chunks, [:vault_id])
    create index(:attachments, [:vault_id])

    # ── RLS for vaults ─────────────────────────────────────────────
    execute "ALTER TABLE vaults ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE vaults FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_vaults ON vaults
      USING (user_id::text = current_setting('app.current_tenant', true))
      WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
    """

    # ── Grant permissions on new tables to engram_app ──────────────
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE plans TO engram_app"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE user_overrides TO engram_app"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE vaults TO engram_app"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE api_key_vaults TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE plans_id_seq TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE user_overrides_id_seq TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE vaults_id_seq TO engram_app"
  end

  def down do
    # Remove grants
    execute "REVOKE ALL ON TABLE plans FROM engram_app"
    execute "REVOKE ALL ON TABLE user_overrides FROM engram_app"
    execute "REVOKE ALL ON TABLE vaults FROM engram_app"
    execute "REVOKE ALL ON TABLE api_key_vaults FROM engram_app"

    # Drop RLS for vaults
    execute "DROP POLICY IF EXISTS tenant_isolation_vaults ON vaults"
    execute "ALTER TABLE vaults DISABLE ROW LEVEL SECURITY"

    # Drop regular vault_id indexes
    drop index(:attachments, [:vault_id])
    drop index(:chunks, [:vault_id])
    drop index(:notes, [:vault_id])

    # Restore original unique indexes on notes and attachments
    drop index(:notes, [:user_id, :vault_id, :path], name: :notes_user_id_vault_id_path_index)

    drop index(:attachments, [:user_id, :vault_id, :path],
           name: :attachments_user_id_vault_id_path_index
         )

    create unique_index(:notes, [:user_id, :path])
    create unique_index(:attachments, [:user_id, :path])

    # Remove vault_id from notes, chunks, attachments
    alter table(:attachments) do
      remove :vault_id
    end

    alter table(:chunks) do
      remove :vault_id
    end

    alter table(:notes) do
      remove :vault_id
    end

    # Drop api_key_vaults join table
    drop table(:api_key_vaults)

    # Drop vaults table (indexes dropped automatically)
    drop table(:vaults)

    # Remove plan_id from users
    alter table(:users) do
      remove :plan_id
    end

    # Drop user_overrides table
    drop table(:user_overrides)

    # Drop plans table
    drop table(:plans)
  end
end
