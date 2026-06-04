# squawk-ignore-file  smoke fixture for migration-safety-tier-1; deleted before merge
defmodule Engram.Repo.Migrations.SmokeUnsafeContract do
  use Ecto.Migration

  # FIXTURE: This migration exists ONLY to exercise the contract-phase grep gate
  # added in feat/migration-safety-tier-1. It must be deleted before the
  # branch is merged. Drops a column referenced by lib/engram/smoke_contract_reference.ex
  # so the gate has something concrete to fail on.

  def change do
    alter table(:users) do
      remove_if_exists(:legacy_smoke_flag, :boolean)
    end
  end
end
