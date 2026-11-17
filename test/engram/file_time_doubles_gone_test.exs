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
  # SQL (a string or a heredoc that is not a doc) and no one-letter query
  # binding (`n.mtime`) names a double.
  test "no lib/ SQL or query binding names a double column" do
    hits =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, n} <- sql_lines(File.read!(path)),
          Regex.match?(~r/\b(mtime|ctime)\b/, line) or
            Regex.match?(~r/(?<![A-Za-z_.])[a-z]\.(mtime|ctime)\b/, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == []
  end

  test "the scan sees heredoc SQL and quoted SQL, not docs" do
    src =
      Enum.join(
        [
          ~s(@doc """),
          "SET the mtime",
          ~s("""),
          ~s(q = """),
          "UPDATE notes SET mtime = 1",
          ~s("""),
          ~s(x = "SELECT ctime FROM notes"),
          "y = n.mtime",
          "Repo.query!(",
          ~s(  """),
          "  SELECT mtime FROM notes",
          ~s(  """,),
          "  [id]",
          ")",
          ~s(  @doc """),
          ~s(      q = """),
          "      SELECT mtime FROM notes",
          ~s(      """),
          "  mtime in prose",
          ~s(  """)
        ],
        "\n"
      )

    assert Enum.map(sql_lines(src), &elem(&1, 1)) == [5, 7, 8, 11]
    # Lines 15-20: a `@doc` holding a heredoc example yields nothing.
  end

  # `{line, number}` for every line that can hold SQL or a query binding:
  # a line inside a heredoc that is not a `@doc` / `@moduledoc`, a quoted
  # line with an SQL keyword, and any non-comment line (for bindings, which
  # the caller matches separately).
  defp sql_lines(src) do
    sql_word = ~r/\b(SELECT|UPDATE|INSERT|WHERE|SET|FROM)\b/

    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(:code, fn {line, n}, mode ->
      trimmed = String.trim(line)
      indent = String.length(line) - String.length(String.trim_leading(line))
      # A heredoc opens on a line ending in `"""` (`q = """`, or a bare
      # `"""` as a call argument) and closes on one starting with it
      # (`"""`, `""",`, `""")`) at no deeper indent than the opener's:
      # a `"""` example nested in a `@doc` is indented further.
      opens? = String.ends_with?(trimmed, ~s("""))

      case mode do
        {kind, open_indent} ->
          cond do
            String.starts_with?(trimmed, ~s(""")) and indent <= open_indent -> {nil, :code}
            kind == :doc -> {nil, mode}
            true -> {{line, n}, mode}
          end

        :code ->
          cond do
            opens? and Regex.match?(~r/@(module)?doc\b/, trimmed) -> {nil, {:doc, indent}}
            opens? -> {nil, {:sql, indent}}
            String.starts_with?(trimmed, "#") -> {nil, :code}
            String.contains?(line, ~s(")) and Regex.match?(sql_word, line) -> {{line, n}, :code}
            Regex.match?(~r/(?<![A-Za-z_.])[a-z]\.(mtime|ctime)\b/, line) -> {{line, n}, :code}
            true -> {nil, :code}
          end
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end
end
