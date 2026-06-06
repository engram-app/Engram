defmodule Engram.Repo.Migrations.CreateAccountExports do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Follows the repo-wide bigserial + varchar(255) + timestamp pattern
  # (see priv/repo/migrations/20260603000010_create_onboarding_actions.exs for
  # the same opt-out rationale). RLS is intentionally not enforced — this
  # table is in @no_rls_allowlist because all access goes through
  # Engram.Accounts.Export with an explicit user_id filter; the partial
  # unique index on (user_id) where status IN ('pending','running') is the
  # per-tenant concurrency boundary.

  def change do
    create table(:account_exports) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :s3_keys, {:array, :map}, default: []
      add :s3_upload_ids, {:array, :map}, default: []
      add :size_bytes, :bigint
      add :error_reason, :string
      add :ready_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :downloaded_at, :utc_datetime_usec
      add :reason, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:account_exports, [:user_id, :inserted_at])
    create index(:account_exports, [:status, :expires_at])

    create unique_index(:account_exports, [:user_id],
             where: "status IN ('pending', 'running')",
             name: :account_exports_one_active_per_user
           )

    # Grant runtime role same access pattern as peer tables.
    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON account_exports TO engram_app",
      "REVOKE ALL ON account_exports FROM engram_app"
    )

    execute(
      "GRANT USAGE, SELECT ON SEQUENCE account_exports_id_seq TO engram_app",
      "REVOKE USAGE, SELECT ON SEQUENCE account_exports_id_seq FROM engram_app"
    )
  end
end
