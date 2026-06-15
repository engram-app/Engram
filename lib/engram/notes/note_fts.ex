defmodule Engram.Notes.NoteFts do
  @moduledoc """
  Side-table row holding the per-note full-text `search_vector` (#595).

  PK is `note_id` (1:1 with `notes`), so this does not use `Engram.Schema`
  (which forces an `:id` PK). The `search_vector` (`tsvector`) is written via a
  raw `setweight(...)` fragment in `Engram.KeywordIndex.Postgres` and never
  loaded into the struct, so it is intentionally not declared as a field.
  """
  use Ecto.Schema

  @primary_key {:note_id, Ecto.UUID, autogenerate: false}
  @foreign_key_type Ecto.UUID

  schema "notes_fts" do
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
