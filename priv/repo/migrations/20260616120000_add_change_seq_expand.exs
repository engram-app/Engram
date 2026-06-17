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

    # fillfactor=80: change_seq is bumped on every write and is in no index,
    # so the row update is HOT-eligible. Reserving page headroom keeps the
    # bump a HOT update so it doesn't churn the 4 vaults secondary indexes.
    # Plain catalog-only DDL — no table rewrite, no transaction required.
    execute("ALTER TABLE public.vaults SET (fillfactor = 80)")

    # (:vault_id, :seq, :id): bulk ops share one seq, so the future ?cursor=
    # pull paginates by (seq, id). The index must carry :id to keep that an
    # index-ordered range scan.
    create index(:notes, [:vault_id, :seq, :id], concurrently: true)
    create index(:attachments, [:vault_id, :seq, :id], concurrently: true)
  end

  def down do
    drop index(:notes, [:vault_id, :seq, :id])
    drop index(:attachments, [:vault_id, :seq, :id])

    execute("ALTER TABLE public.vaults RESET (fillfactor)")

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
