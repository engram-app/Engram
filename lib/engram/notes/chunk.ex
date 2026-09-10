defmodule Engram.Notes.Chunk do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "chunks" do
    field :position, :integer
    field :heading_path, :string
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

    belongs_to :note, Engram.Notes.Note
    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :position,
      :heading_path,
      :char_start,
      :char_end,
      :token_count,
      :qdrant_point_id,
      :context_hmac,
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
