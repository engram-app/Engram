defmodule Engram.Repo.Migrations.IndexChunksWithText do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The DEK rotation sweep visits only chunk rows that hold an envelope
  # (`Engram.Crypto.TenantSweep`). Partial on NOT NULL: only notes over the
  # display threshold store one, so the index stays small and a sweep costs
  # one probe per user instead of a page through every chunk. CONCURRENTLY:
  # no write lock on `chunks`.
  def change do
    create index(:chunks, [:user_id, :id],
             name: :chunks_with_display_user_id_id_index,
             where: "display_ct IS NOT NULL",
             concurrently: true
           )
  end
end
