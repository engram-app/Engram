defmodule Engram.Repo.Migrations.CiphertextStorageExternalNotes do
  use Ecto.Migration

  # STORAGE EXTERNAL (out of line, no TOAST compression) on ciphertext whose
  # payload is zstd-compressed before it is encrypted (`Engram.Crypto.Envelope`
  # @policy). Ciphertext does not compress, so Postgres' lz4 attempt on every
  # write is CPU spent for nothing (2026-10-20 audit). New writes only; nothing
  # is rewritten. crdt_update_log and idempotency_keys ciphertext are not in the
  # zstd policy and keep the default.
  #
  # SET STORAGE is catalog-only but takes ACCESS EXCLUSIVE. One table per
  # migration (so per transaction), so the lock is held only for its own
  # change, and lock_timeout makes a busy table fail the migration (the
  # release retries on the next boot) rather than queue every writer behind
  # it. SET LOCAL: it ends with this migration's transaction.

  def up, do: set_storage("EXTERNAL")

  # EXTENDED is the default for bytea.
  def down, do: set_storage("EXTENDED")

  defp set_storage(mode) do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE notes ALTER COLUMN content_ciphertext SET STORAGE #{mode}"
    execute "ALTER TABLE notes ALTER COLUMN crdt_state_ciphertext SET STORAGE #{mode}"
  end
end
