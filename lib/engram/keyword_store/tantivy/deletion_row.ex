defmodule Engram.KeywordStore.Tantivy.DeletionRow do
  @moduledoc """
  One `keyword_deletions` row: the durable log of note, vault and user
  deletes a restored kwsearch snapshot re-applies before it serves.
  """
  use Ecto.Schema

  @primary_key {:seq, :id, autogenerate: true}
  schema "keyword_deletions" do
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :note_id, :binary_id
    field :op, :integer
  end
end
