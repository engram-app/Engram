defmodule Engram.Repo.Migrations.CreateStorageObjects do
  use Ecto.Migration

  # Self-host bytea storage backend (#297). Generic opaque-blob store keyed by
  # the same `user_id/vault_id/path` storage_key the S3 adapter uses, letting a
  # minified self-host stack drop MinIO. NOT a revival of the old
  # `attachments.content` column (removed in A.5/PR #62) — values are already
  # ciphertext from the caller, so this table stores encrypted bytes.
  def change do
    create table(:storage_objects, primary_key: false) do
      add :storage_key, :text, primary_key: true
      add :data, :binary, null: false
      add :byte_size, :bigint, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
