defmodule Engram.Repo.Migrations.CreateAccountExports do
  use Ecto.Migration

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
  end
end
