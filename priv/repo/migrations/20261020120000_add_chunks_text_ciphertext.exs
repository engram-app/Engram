defmodule Engram.Repo.Migrations.AddChunksTextCiphertext do
  use Ecto.Migration

  # Expand-only: two nullable columns, no backfill, no default.
  #
  # A chunk's display text for search (Task 11.1, hybrid design):
  #   * `text_sum`: CRC32 of the display text, on every row written with the
  #     write flag on. Search re-derives the text from the note content and
  #     checks it, so a note edited since its index is detected.
  #   * `display_ct`: the text and heading in ONE envelope, bound to
  #     `qdrant_point_id`, only for notes over the size threshold (a hit there
  #     would otherwise decrypt and re-chunk a huge note).
  # NULL on rows written while the write flag is off; search then falls back
  # to the payload. `chunks` already has FORCE RLS and the `maintenance_all`
  # policy, which cover new columns. The v5 rebuild pass writes every row;
  # no backfill here.
  def change do
    alter table(:chunks) do
      add :text_sum, :integer
      add :display_ct, :binary
    end
  end
end
