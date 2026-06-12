defmodule Engram.Notes.Chunk do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "chunks" do
    field :position, :integer
    field :heading_path, :string
    field :char_start, :integer
    field :char_end, :integer
    field :qdrant_point_id, Ecto.UUID

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
      :qdrant_point_id,
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
