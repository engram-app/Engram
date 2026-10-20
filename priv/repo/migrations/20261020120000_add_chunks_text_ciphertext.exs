defmodule Engram.Repo.Migrations.AddChunksTextCiphertext do
  use Ecto.Migration

  # Expand-only: four nullable columns, no backfill, no default.
  #
  # A chunk's display text and heading, encrypted with the user's DEK and
  # bound to `qdrant_point_id` (Task 11.1), so search reads them from
  # Postgres and a v5 point carries no text. NULL on rows written while the
  # write flag is off; search then falls back to the payload. `chunks`
  # already has FORCE RLS and the `maintenance_all` policy, which cover new
  # columns. The v5 rebuild pass writes every row; no backfill here.
  def change do
    alter table(:chunks) do
      add :text_ciphertext, :binary
      add :text_nonce, :binary
      add :heading_ciphertext, :binary
      add :heading_nonce, :binary
    end
  end
end
