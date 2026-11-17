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

  # Raw SQL would only fail at runtime in whatever test runs it: no lib/
  # SQL string or one-letter query binding (`n.mtime`) names a double.
  test "no lib/ SQL or query binding names a double column" do
    sql_word = ~r/\b(SELECT|UPDATE|INSERT|WHERE|SET|FROM)\b/
    double = ~r/\b(mtime|ctime)\b/
    binding = ~r/(?<![A-Za-z_.])[a-z]\.(mtime|ctime)\b/

    hits =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          (Regex.match?(sql_word, line) and Regex.match?(double, line) and
             String.contains?(line, ~s("))) or Regex.match?(binding, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == []
  end
end
