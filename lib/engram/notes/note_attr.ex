defmodule Engram.Notes.NoteAttr do
  @moduledoc """
  One v5 frontmatter filter value of a note (spec 3.3b): a per-user `key_id`
  (`Engram.Notes.FrontmatterKeys`: reserved ids for the named fields, a
  dictionary id for a user-added key), its position `ord` in that key's list
  (0 for a scalar), and exactly one of `h` (an exact value, a 32-byte HMAC
  under the per-user filter key), `n` (a number) or `d` (a date, unix
  seconds). Written by the indexing pass from the same extraction as the
  Qdrant payload (`Engram.Notes.FlatFields`). RLS-scoped on `user_id`.

  HMAC domains: `h` is `FilterId.value_hmac/2` for every key EXCEPT `type`
  (id 0) and `tags` (id 1), which reuse the note row's blind indexes
  (`notes.type_hmac` / `tags_hmac`: `Crypto.hmac_field(fk, normalized)`, no
  `fmv:` prefix), so a reader must compute those two the way `Search` does.

  Readers (follow-up Engram#2083) MUST scope by `vault_id` and join `notes`
  to exclude soft-deleted notes (`deleted_at IS NULL`): rows are replaced on
  each index pass but survive a soft delete until the note is purged.
  """
  use Ecto.Schema

  @primary_key false

  schema "note_attrs" do
    field :note_id, :binary_id, primary_key: true
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :n, :float
    field :d, :integer
    field :key_id, :integer, primary_key: true
    field :ord, :integer, primary_key: true
    field :h, :binary
  end
end
