defmodule Engram.Notes.ChunkPoint do
  @moduledoc """
  One row per Qdrant point: what search shows for a hit (Task 11, lean
  table, notes-chunks-hyperopt 2.4/2.4b). Written next to `chunks`, in the
  same transaction, behind `:chunk_text_write`; read behind
  `:chunk_text_read`.

  `slice_sum` is the CRC32 of the chunk's display text (`Indexing.text_sum/1`);
  search re-derives a small note's chunk from its content and checks it.
  `display_ct` holds the text and heading in ONE envelope
  (`Crypto.encrypt_chunk_text/4`), only for notes over
  `Indexing.display_ct_threshold/0`. `member_fps`: a merged point's member
  fingerprints, 8-byte prefixes concatenated.
  """
  use Ecto.Schema

  @primary_key {:point_id, Ecto.UUID, autogenerate: false}
  @foreign_key_type Ecto.UUID

  schema "chunk_points" do
    field :note_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :char_start, :integer
    field :char_end, :integer
    field :token_count, :integer
    field :slice_sum, :integer
    field :position, :integer
    field :member_fps, :binary
    field :display_ct, :binary, redact: true
  end
end
