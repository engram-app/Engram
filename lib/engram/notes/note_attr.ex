defmodule Engram.Notes.NoteAttr do
  @moduledoc """
  One long-tail v5 frontmatter filter value of a note (spec 3.3b): a
  `key_hmac` and exactly one of `value_hmac` (strings, booleans), `value_num`
  or `value_date` (unix seconds). Written by the indexing pass from the same
  extraction as the Qdrant `fm_attrs` / `fm_nums` / `fm_dates`
  (`Engram.Notes.FlatFields`). RLS-scoped on `user_id`.

  Readers (follow-up Engram#2083) MUST scope by `vault_id` and join `notes`
  to exclude soft-deleted notes (`deleted_at IS NULL`): rows are replaced on
  each index pass but survive a soft delete until the note is purged.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id

  schema "note_attrs" do
    field :note_id, :binary_id
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :key_hmac, :binary
    field :value_hmac, :binary
    field :value_num, :float
    field :value_date, :integer
  end
end
