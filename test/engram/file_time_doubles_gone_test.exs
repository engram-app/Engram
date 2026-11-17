defmodule Engram.FileTimeDoublesGoneTest do
  @moduledoc """
  R25 contract step (c) guard: the epoch double columns are dropped and no
  schema maps them. `mtime` / `ctime` survive only as virtual (cast-only)
  fields, so no query names a column that is gone.
  """
  use Engram.DataCase, async: true

  @tables %{
    "notes" => ~w(mtime ctime),
    "attachments" => ~w(mtime),
    "attachment_uploads" => ~w(mtime)
  }

  test "the double columns are gone; the timestamps remain" do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name, column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = ANY($1)",
        [Map.keys(@tables)]
      )

    for {table, cols} <- @tables, col <- cols do
      refute [table, col] in rows, "#{table}.#{col} still exists"
      assert [table, "#{col}_at"] in rows
    end
  end

  test "the schemas map no double: mtime/ctime are virtual" do
    for {schema, fields} <- [
          {Engram.Notes.Note, [:mtime, :ctime]},
          {Engram.Attachments.Attachment, [:mtime]},
          {Engram.Attachments.Upload, [:mtime]}
        ],
        f <- fields do
      refute f in schema.__schema__(:fields), inspect({schema, f})
      assert f in schema.__schema__(:virtual_fields), inspect({schema, f})
    end
  end
end
