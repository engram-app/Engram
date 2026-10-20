defmodule Engram.Notes.NoteAttr do
  @moduledoc """
  One v5 frontmatter filter value of a note (spec 3.3b): a per-user `key_id`
  (`Engram.Notes.FrontmatterKeys`: reserved ids for the named fields, a
  dictionary id for a user-added key) and exactly one of `h` (an exact value,
  a 32-byte HMAC under the per-user filter key), `n` (a number) or `d` (a
  date, unix seconds). Written by the indexing pass from the same extraction
  as the Qdrant payload (`Engram.Notes.FlatFields`). RLS-scoped on `user_id`.

  Readers (follow-up Engram#2083) MUST scope by `vault_id` and join `notes`
  to exclude soft-deleted notes (`deleted_at IS NULL`): rows are replaced on
  each index pass but survive a soft delete until the note is purged.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}

  schema "note_attrs" do
    field :note_id, :binary_id
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :key_id, :integer
    field :h, :binary
    field :n, :float
    field :d, :integer
  end
end
