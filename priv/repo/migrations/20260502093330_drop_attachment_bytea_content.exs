defmodule Engram.Repo.Migrations.DropAttachmentByteaContent do
  use Ecto.Migration

  # A.5 (PR #62) — retires the BYTEA `content` column now that all attachments
  # are encrypted-at-rest in S3-compatible object storage. Saas + selfhost both
  # verified at zero `WHERE encryption_version = 0 AND content IS NOT NULL` rows
  # before merge (2026-05-02). The legacy `Storage.Database` adapter and the
  # backfill worker are removed in the same PR.
  #
  # IRREVERSIBLE: rolling back would require decrypting every S3 object and
  # re-writing the plaintext into the column, which Engram does not support.

  def up do
    drop index(:attachments, [:vault_id, :id], name: :attachments_legacy_plaintext_idx)

    alter table(:attachments) do
      remove :content
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "DropAttachmentByteaContent is irreversible — restoring the column would " <>
          "require decrypting every S3 object and rewriting plaintext into Postgres."
  end
end
