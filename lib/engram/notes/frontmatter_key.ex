defmodule Engram.Notes.FrontmatterKey do
  @moduledoc "One row of the per-user frontmatter key dictionary (`Engram.Notes.FrontmatterKeys`)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false

  schema "frontmatter_keys" do
    field :user_id, :binary_id, primary_key: true
    field :key_id, :integer, primary_key: true
    field :key_hmac, :binary
    field :name_ct, :binary
    field :name_nonce, :binary
    field :inserted_at, :utc_datetime, read_after_writes: true
  end
end
