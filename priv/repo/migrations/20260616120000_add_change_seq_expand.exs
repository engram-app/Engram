defmodule Engram.Repo.Migrations.AddChangeSeqExpand do
  use Ecto.Migration

  @moduledoc """
  Sync change-log backbone, step A. phase/expand: purely additive.
  - vaults.change_seq: per-vault monotonic counter (source of seq values).
  - notes.seq / attachments.seq: latest change sequence per row (nullable
    until backfilled in 20260616120100_backfill_seq).
  CREATE INDEX CONCURRENTLY requires no surrounding transaction.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:vaults) do
      add :change_seq, :bigint, null: false, default: 0
    end

    alter table(:notes) do
      add :seq, :bigint
    end

    alter table(:attachments) do
      add :seq, :bigint
    end

    create index(:notes, [:vault_id, :seq], concurrently: true)
    create index(:attachments, [:vault_id, :seq], concurrently: true)
  end

  def down do
    drop index(:notes, [:vault_id, :seq])
    drop index(:attachments, [:vault_id, :seq])

    alter table(:notes) do
      remove :seq
    end

    alter table(:attachments) do
      remove :seq
    end

    alter table(:vaults) do
      remove :change_seq
    end
  end
end
