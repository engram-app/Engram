defmodule Engram.Repo.Migrations.IndexBasenameHmacExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # phase/expand — CONCURRENTLY: notes/attachments are populated tables.
  def change do
    create index(:notes, [:user_id, :vault_id, :basename_hmac],
             concurrently: true,
             where: "deleted_at IS NULL"
           )

    create index(:attachments, [:user_id, :vault_id, :basename_hmac],
             concurrently: true,
             where: "deleted_at IS NULL"
           )
  end
end
