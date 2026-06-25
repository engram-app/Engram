defmodule Engram.Notes.CrdtUpdateLog do
  @moduledoc "Append-only encrypted Yjs update-log row. Compacted on checkpoint."
  use Engram.Schema
  import Ecto.Changeset

  schema "crdt_update_log" do
    field :note_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :update_ciphertext, :binary
    field :update_nonce, :binary
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :id,
      :note_id,
      :user_id,
      :vault_id,
      :update_ciphertext,
      :update_nonce
    ])
    |> validate_required([
      :note_id,
      :user_id,
      :vault_id,
      :update_ciphertext,
      :update_nonce
    ])
  end
end
