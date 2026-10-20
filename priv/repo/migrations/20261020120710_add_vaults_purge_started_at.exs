defmodule Engram.Repo.Migrations.AddVaultsPurgeStartedAt do
  use Ecto.Migration

  @moduledoc """
  `vaults.purge_started_at`: set by `Engram.Workers.CleanupVault` before its
  first delete batch. The purge commits in batches, so one that fails for good
  leaves a soft-deleted vault with some rows gone; `Vaults.restore_vault/2`
  refuses a vault with this set rather than hand it back partial.

  Nullable, no default, no backfill: NULL means no purge has started, which is
  true of every existing row. A metadata-only ALTER; purely additive.
  """

  def change do
    alter table(:vaults) do
      add :purge_started_at, :utc_datetime
    end
  end
end
