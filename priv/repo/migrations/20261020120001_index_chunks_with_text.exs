defmodule Engram.Repo.Migrations.IndexChunksWithText do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The DEK rotation and envelope re-encode sweeps visit only chunk rows that
  # hold text (`Engram.Crypto.TenantSweep`). Partial on NOT NULL, so with the
  # chunk-text write flag off the index is empty and a sweep costs one probe
  # per user instead of a page through every chunk. CONCURRENTLY: no write
  # lock on `chunks`.
  def change do
    create index(:chunks, [:user_id, :id],
             name: :chunks_with_text_user_id_id_index,
             where: "text_ciphertext IS NOT NULL",
             concurrently: true
           )
  end
end
