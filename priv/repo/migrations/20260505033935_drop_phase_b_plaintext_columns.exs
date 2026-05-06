defmodule Engram.Repo.Migrations.DropPhaseBPlaintextColumns do
  use Ecto.Migration

  # Phase B.3 — drops the plaintext path/folder/tags/name columns. By this
  # point, B.1's backfill + B.2's read switch + Qdrant payload re-upsert have
  # been live and verified at zero `*_hmac IS NULL` rows on every container.
  #
  # IRREVERSIBLE: rolling back would require decrypting every ciphertext
  # column and re-populating the plaintext columns, which is supported only
  # via a forward migration not a `down/0` step.

  def up do
    # Replace the plaintext-path uniqueness gate with an HMAC-keyed equivalent
    # before dropping the source columns. Without this, dropping `notes.path`
    # / `attachments.path` would also drop the only unique constraint on the
    # write path. We also drop the existing non-unique HMAC indexes so the
    # new unique partial indexes carry the lookups too.
    drop index(:notes, [:user_id, :vault_id, :path_hmac],
           name: :notes_user_id_vault_id_path_hmac_index
         )

    drop index(:attachments, [:user_id, :vault_id, :path_hmac],
           name: :attachments_user_id_vault_id_path_hmac_index
         )

    create unique_index(:notes, [:user_id, :vault_id, :path_hmac],
             name: :notes_user_id_vault_id_path_hmac_index,
             where: "deleted_at IS NULL"
           )

    create unique_index(:attachments, [:user_id, :vault_id, :path_hmac],
             name: :attachments_user_id_vault_id_path_hmac_index,
             where: "deleted_at IS NULL"
           )

    # Drop plaintext columns. PostgreSQL auto-drops dependent indexes:
    # idx_notes_tags (GIN on tags), idx_notes_user_folder (btree on
    # user_id, folder), notes_user_id_vault_id_path_index (UNIQUE on path),
    # attachments_user_id_vault_id_path_index (UNIQUE on path).
    alter table(:notes) do
      remove :path
      remove :folder
      remove :tags
    end

    alter table(:attachments) do
      remove :path
    end

    alter table(:vaults) do
      remove :name
    end

    # Tighten — every row must now have ciphertext + HMAC + nonce
    alter table(:notes) do
      modify :path_hmac, :binary, null: false
      modify :path_ciphertext, :binary, null: false
      modify :path_nonce, :binary, null: false
      modify :folder_hmac, :binary, null: false
      modify :folder_ciphertext, :binary, null: false
      modify :folder_nonce, :binary, null: false
    end

    alter table(:attachments) do
      modify :path_hmac, :binary, null: false
      modify :path_ciphertext, :binary, null: false
      modify :path_nonce, :binary, null: false
    end

    alter table(:vaults) do
      modify :name_hmac, :binary, null: false
      modify :name_ciphertext, :binary, null: false
      modify :name_nonce, :binary, null: false
    end

    # Phase B.3 retires whole-vault decryption (worker + endpoints + Crypto
    # API all deleted). Cancel any in-flight DecryptVault jobs from before
    # this deploy — Oban would otherwise log "unknown worker" on each
    # attempt-and-retry-cycle through max_attempts. Flip any stuck
    # `decrypt_pending` / `decrypting` vault rows back to `encrypted` so
    # status-poller UIs don't strand waiting on a transition that no longer
    # exists.
    execute(
      "UPDATE oban_jobs SET state = 'cancelled', cancelled_at = NOW() " <>
        "WHERE worker = 'Engram.Workers.DecryptVault' " <>
        "AND state IN ('available', 'scheduled', 'retryable', 'executing')"
    )

    execute(
      "UPDATE vaults SET encryption_status = 'encrypted', encrypted = true " <>
        "WHERE encryption_status IN ('decrypt_pending', 'decrypting')"
    )
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "DropPhaseBPlaintextColumns is irreversible — restoring requires " <>
          "decrypting every ciphertext column and re-populating plaintext, " <>
          "which is not supported via Ecto down migrations."
  end
end
