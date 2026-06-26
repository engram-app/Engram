defmodule Engram.Repo.Migrations.CreateCrdtUpdateLogExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — new append-only table; no backfill. Each row is ONE encrypted
  # Yjs v1 update, AAD-bound to the note via reuse of the notes-row crypto. Rows
  # are compacted into the notes.crdt_state snapshot on checkpoint, then pruned.
  # RLS mirrors the onboarding_actions/notes pattern — tenant-scoped by user_id.
  def change do
    create table(:crdt_update_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :note_id, references(:notes, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :update_ciphertext, :binary, null: false
      add :update_nonce, :binary, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:crdt_update_log, [:note_id, :inserted_at])
    # Cover the user_id / vault_id FKs (on_delete: :delete_all → cascade scans;
    # user_id is also matched by the tenant_isolation RLS predicate on every row).
    create index(:crdt_update_log, [:user_id])
    create index(:crdt_update_log, [:vault_id])

    execute(
      "ALTER TABLE crdt_update_log ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE crdt_update_log DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE crdt_update_log FORCE ROW LEVEL SECURITY",
      "ALTER TABLE crdt_update_log NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_crdt_update_log ON crdt_update_log
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_crdt_update_log ON crdt_update_log"
    )

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON crdt_update_log TO engram_app",
      "REVOKE ALL ON crdt_update_log FROM engram_app"
    )
  end
end
