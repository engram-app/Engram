defmodule Engram.Repo.Migrations.AddChunksContextHmacExpand do
  use Ecto.Migration

  # phase/expand — nullable column, no default, no rewrite.
  #
  # Per-chunk fingerprint of the string we actually embed (`context_text` =
  # "folder > title > heading\n\ntext"), so a re-index can tell which chunks
  # changed instead of re-embedding all of them (#1592).
  #
  # No index: nothing queries BY this column. The reuse map is built from the
  # note's own chunk rows, which `chunks_note_id_position_index` already
  # covers on its `note_id` prefix.
  #
  # Nullable on purpose and never backfilled. The chunk text lives encrypted
  # in Qdrant, not in Postgres, so existing rows cannot be hashed after the
  # fact. `nil` reads as "changed", which degrades exactly to today's
  # full-re-embed behaviour; the first re-index of each note fills it in.
  def change do
    alter table(:chunks) do
      add :context_hmac, :string
    end
  end
end
