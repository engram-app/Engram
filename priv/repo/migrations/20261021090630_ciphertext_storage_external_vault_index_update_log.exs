defmodule Engram.Repo.Migrations.CiphertextStorageExternalVaultIndexUpdateLog do
  use Ecto.Migration

  # Same as CiphertextStorageExternalNotes: one table per migration so each
  # ACCESS EXCLUSIVE is held only for its own catalog change.

  def up, do: set_storage("EXTERNAL")

  # EXTENDED is the default for bytea.
  def down, do: set_storage("EXTENDED")

  defp set_storage(mode) do
    execute "SET LOCAL lock_timeout = '5s'"

    execute "ALTER TABLE vault_index_update_log ALTER COLUMN update_ciphertext SET STORAGE #{mode}"
  end
end
