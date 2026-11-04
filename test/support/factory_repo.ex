defmodule Engram.FactoryRepo do
  @moduledoc """
  The repo `Engram.Factory` inserts through: `Engram.Repo.insert!/2`, then,
  for a note, its body row as every app writer leaves it
  (`Engram.Notes.NoteBody.sync!/3`). Prod never holds a note without one
  (the copy trigger that used to make it is gone), so neither does a test
  unless it deletes the row and says why.
  """

  alias Engram.Notes.{Note, NoteBody}

  def insert!(struct_or_changeset, opts \\ []) do
    case Engram.Repo.insert!(struct_or_changeset, opts) do
      %Note{kind: "note", id: id} = note ->
        _ = NoteBody.sync!(id, [])
        note

      other ->
        other
    end
  end
end
