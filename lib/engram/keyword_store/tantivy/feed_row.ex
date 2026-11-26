defmodule Engram.KeywordStore.Tantivy.FeedRow do
  @moduledoc """
  One `keyword_feed` row (the kwsearch outbox; `Engram.KeywordStore.Tantivy.Feed`
  writes them). `xid` and `inserted_at` are column defaults, set by Postgres;
  `xid` is an `xid8` and read only by kwsearch and the trim, as text.
  """
  use Ecto.Schema

  @primary_key {:seq, :id, autogenerate: true}
  schema "keyword_feed" do
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :note_id, :binary_id
    field :point_id, :binary_id
    field :stamp, :integer, default: 0
    field :index_set, :integer, default: 1
    field :op, :integer
    field :terms, :binary
    field :keep, {:array, :binary_id}
  end
end
