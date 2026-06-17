defmodule Engram.Repo.Migrations.CursorPullExpand do
  use Ecto.Migration

  @moduledoc """
  Sync cursor pull, step B1. phase/expand: purely additive.
  - vault_device_cursors: per-(vault,device) sync watermark (GC + eviction).
    Composite PRIMARY KEY (vault_id, device_id) — the table's natural key,
    matching `Engram.Sync.DeviceCursor`'s composite primary_key. The PK
    supplies the uniqueness + index the ON CONFLICT upsert targets, and its
    leading vault_id column covers the FK, so no separate index is needed.
  - attachments.version: optimistic-concurrency / resurrection-safety parity
    with notes.version (nullable->default 1; bumped on write).

  Fully transactional: a new (empty) table + a metadata-only NOT NULL column
  add with a constant default (PG11+) need no CONCURRENTLY, so no
  @disable_ddl_transaction.
  """

  def up do
    create table(:vault_device_cursors, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :device_id, :text, null: false, primary_key: true
      add :last_seq, :bigint, null: false, default: 0
      add :last_seen_at, :utc_datetime, null: false
    end

    alter table(:attachments) do
      add :version, :integer, null: false, default: 1
    end
  end

  def down do
    alter table(:attachments) do
      remove :version
    end

    drop table(:vault_device_cursors)
  end
end
