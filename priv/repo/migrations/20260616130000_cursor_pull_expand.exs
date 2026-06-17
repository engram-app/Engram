defmodule Engram.Repo.Migrations.CursorPullExpand do
  use Ecto.Migration

  @moduledoc """
  Sync cursor pull, step B1. phase/expand: purely additive.
  - vault_device_cursors: per-(vault,device) sync watermark (GC + eviction).
  - attachments.version: optimistic-concurrency / resurrection-safety parity
    with notes.version (nullable->default 1; bumped on write).
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create table(:vault_device_cursors, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), null: false
      add :device_id, :text, null: false
      add :last_seq, :bigint, null: false, default: 0
      add :last_seen_at, :utc_datetime, null: false
    end

    create unique_index(:vault_device_cursors, [:vault_id, :device_id], concurrently: true)

    alter table(:attachments) do
      add :version, :integer, null: false, default: 1
    end
  end

  def down do
    alter table(:attachments) do
      remove :version
    end

    drop index(:vault_device_cursors, [:vault_id, :device_id])
    drop table(:vault_device_cursors)
  end
end
