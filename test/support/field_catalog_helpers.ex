defmodule Engram.FieldCatalogHelpers do
  @moduledoc """
  Writes a note and its `note_attrs` rows the way the v5 indexing pass does
  (`FlatFields.extract` -> `FrontmatterKeys.resolve` -> `FlatFields.attr_rows`),
  without the embedder or Qdrant: the catalog reads only Postgres.
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.FlatFields
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.NoteAttr
  alias Engram.Repo

  def write_indexed!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(User, user.id)
    {:ok, fk} = Crypto.dek_filter_key(user)
    {:ok, dek} = Crypto.get_dek(user)
    flat = FlatFields.extract(content, fk)
    {ids, 0} = FrontmatterKeys.resolve(user.id, dek, flat.names)
    rows = flat |> FlatFields.put_key_ids(ids) |> FlatFields.attr_rows(note)

    Repo.with_tenant!(user.id, fn ->
      Repo.delete_all(from(a in NoteAttr, where: a.note_id == ^note.id))
      Repo.insert_all(NoteAttr, rows)
    end)

    note
  end
end
