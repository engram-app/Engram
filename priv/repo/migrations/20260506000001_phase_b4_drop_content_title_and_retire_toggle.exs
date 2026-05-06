defmodule Engram.Repo.Migrations.PhaseB4DropContentTitleAndRetireToggle do
  use Ecto.Migration

  # Phase B.4 — drops the last user-content plaintext columns and retires
  # the encryption toggle entirely.
  #
  # B.3 dropped path/folder/tags/name plaintext + retired the decrypt half
  # of the toggle. B.4 drops content/title plaintext and the encrypt half:
  # `vault.encrypted`, `vault.encryption_status`, `vault.encrypted_at`,
  # `vault.decrypt_requested_at`, `vault.last_toggle_at`, plus
  # `users.encryption_toggle_cooldown_days`.
  #
  # IRREVERSIBLE — restoring requires decrypting every ciphertext row and
  # re-populating plaintext, which is not a supported `down/0` operation.
  #
  # Pre-merge probes (saas, 2026-05-05 / `docs/encryption-tier-2-plan.md`):
  #   - 0 plaintext-only notes (every row has either ciphertext or both)
  #   - 0 vaults with encrypted=false on saas (all 10 toggled in B.3 prep)
  #   - selfhost: 0 notes, 2 empty vaults; safe to drop regardless of flag
  #     since `name_ciphertext` is already NOT NULL post-B.3.

  def up do
    # Drop content/title plaintext from notes. ciphertext columns already
    # carry the canonical body; B.3 made decrypt mandatory on every read.
    alter table(:notes) do
      remove :content
      remove :title
    end

    # Tighten — every row must now have content/title/tags ciphertext + nonce.
    alter table(:notes) do
      modify :content_ciphertext, :binary, null: false
      modify :content_nonce, :binary, null: false
      modify :title_ciphertext, :binary, null: false
      modify :title_nonce, :binary, null: false
      modify :tags_ciphertext, :binary, null: false
      modify :tags_nonce, :binary, null: false
    end

    # Retire the toggle on vaults. After this, every vault is encrypted by
    # definition — there is no flag to flip and no transitional status.
    alter table(:vaults) do
      remove :encrypted
      remove :encryption_status
      remove :encrypted_at
      remove :decrypt_requested_at
      remove :last_toggle_at
    end

    # Cooldown was a per-user throttle on toggle frequency. With no toggle,
    # there is nothing to throttle.
    alter table(:users) do
      remove :encryption_toggle_cooldown_days
    end

    # Cancel any in-flight EncryptVault jobs queued before this deploy. The
    # worker module is deleted in this PR; Oban would otherwise log "unknown
    # worker" through max_attempts on each.
    execute(
      "UPDATE oban_jobs SET state = 'cancelled', cancelled_at = NOW() " <>
        "WHERE worker = 'Engram.Workers.EncryptVault' " <>
        "AND state IN ('available', 'scheduled', 'retryable', 'executing')"
    )
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "PhaseB4DropContentTitleAndRetireToggle is irreversible — restoring " <>
          "requires decrypting every ciphertext column and re-populating " <>
          "plaintext, which is not supported via Ecto down migrations."
  end
end
