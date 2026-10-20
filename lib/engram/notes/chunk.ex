defmodule Engram.Notes.Chunk do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "chunks" do
    field :position, :integer
    # No `heading_path`: the plaintext column is never written or read (the
    # heading lives encrypted in the Qdrant payload) and is dropped by the
    # next contract release. Removed from the schema first so that release
    # cannot break this one mid-deploy.
    field :char_start, :integer
    field :char_end, :integer
    field :token_count, :integer
    field :qdrant_point_id, Ecto.UUID
    # HMAC of the chunk's `context_text` — the exact string handed to the
    # embedder. Equal hmac means the dense vector, the sparse vector and all
    # three encrypted payload fields are reusable as-is (#1592). Nil on rows
    # written before the column existed, and after a DEK rotation invalidates
    # the key; both read as "changed".
    field :context_hmac, :string
    # Merged rows only: each member chunk's fingerprint, leading 16 hex
    # chars. See `Engram.Indexing.cap_chunks/4`.
    field :member_hmacs, {:array, :string}
    # Display text (Task 11.1, hybrid). `text_sum`: CRC32 of the chunk's
    # display text, signed int4, on every row written with the write flag on;
    # search re-derives the text from the note content and checks it.
    # `display_ct`: the text and heading in ONE envelope
    # (`Crypto.encrypt_chunk_text/4`), only for notes over
    # `Engram.Indexing.display_ct_threshold/0`. Both nil while the flag is off.
    field :text_sum, :integer
    field :display_ct, :binary, redact: true

    belongs_to :note, Engram.Notes.Note
    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :position,
      :char_start,
      :char_end,
      :token_count,
      :qdrant_point_id,
      :context_hmac,
      :member_hmacs,
      :note_id,
      :user_id,
      :vault_id
    ])
    |> validate_required([
      :position,
      :char_start,
      :char_end,
      :qdrant_point_id,
      :note_id,
      :user_id,
      :vault_id
    ])
    |> unique_constraint([:note_id, :position])
  end
end
