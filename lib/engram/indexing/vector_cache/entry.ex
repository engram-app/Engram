defmodule Engram.Indexing.VectorCache.Entry do
  @moduledoc """
  One `embedding_cache` row (`Engram.Indexing.VectorCache`). The hot paths
  (`get_many/3`, `put_many/4`) are raw SQL over arrays; this schema serves the
  rotation sweep and names the table for the tenant lints.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "embedding_cache" do
    field :user_id, :binary_id, primary_key: true
    field :key, :binary, primary_key: true
    field :note_id, :binary_id
    field :vector_ciphertext, :binary
    field :vector_nonce, :binary
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
