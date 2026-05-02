defmodule Engram.Repo.Migrations.AddAttachmentEncryption do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :encryption_version, :integer, null: false, default: 0
      add :content_nonce, :binary
    end

    create index(:attachments, [:encryption_version],
             where: "encryption_version = 0",
             name: :attachments_legacy_plaintext_idx
           )
  end
end
