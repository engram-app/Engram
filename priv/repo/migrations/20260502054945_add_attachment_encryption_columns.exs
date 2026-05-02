defmodule Engram.Repo.Migrations.AddAttachmentEncryptionColumns do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :encryption_version, :integer, default: 0, null: false
      add :content_nonce, :binary
    end

    # Partial index on legacy plaintext rows so the backfill scan is cheap
    # even after most rows are migrated.
    create index(:attachments, [:vault_id, :id],
             where: "encryption_version = 0 AND content IS NOT NULL",
             name: :attachments_legacy_plaintext_idx
           )
  end
end
