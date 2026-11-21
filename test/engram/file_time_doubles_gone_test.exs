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

  # The one non-doc heredoc that names a double and is not SQL: the MCP
  # attachment tool's prose, which names the `mtime` wire param.
  @prose_exempt {"lib/engram/mcp/handlers.ex", "&mtime=<unix seconds>"}

  # Raw SQL would only fail at runtime in whatever test runs it: no lib/
  # SQL (a string or a heredoc that is not a doc) and no one-letter query
  # binding (`n.mtime`) names a double. The migrations' `# safety_assured`
  # turns the migration-gates reference grep off, so this is the only
  # static check left.
  test "no lib/ SQL or query binding names a double column" do
    {exempt_path, exempt_text} = @prose_exempt

    hits =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, n} <- sql_lines(File.read!(path)),
          Regex.match?(~r/\b(mtime|ctime)\b/, line) or
            Regex.match?(~r/(?<![A-Za-z_.])[a-z]\.(mtime|ctime)\b/, line),
          not (path == exempt_path and String.contains?(line, exempt_text)),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == []
  end

  # 0.88.0 still maps the doubles as real schema fields (note.ex,
  # attachment.ex, upload.ex), so it fails every note and attachment read
  # once these columns are gone. 0.89.0 (R25 step b) is the first release
  # that neither reads nor writes them. The drop may ship only when no
  # rollback target is older than that.
  test "the rollback floor is past the last release that maps the doubles" do
    assert Engram.Release.Floor.at_least?("release-v0.89.0")
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
          ~s(  """),
          ~s(q = """),
          "-- a comment first",
          "UPDATE notes SET mtime = 1",
          ~s("""),
          ~s[x = "COALESCE(mtime, 0)"],
          ~s(x = "select mtime from notes"),
          ~s[fragment("""],
          "COALESCE(ctime, 0)",
          ~s(""")
        ],
        "\n"
      )

    # Lines 15-20: a `@doc` holding a heredoc example yields nothing.
    # 22-23: every line of a non-doc heredoc, a `--` comment first or not.
    # 25-26: quoted SQL by function call or lowercase keyword. 28: a
    # `fragment("""` heredoc.
    assert Enum.map(sql_lines(src), &elem(&1, 1)) == [5, 7, 8, 11, 22, 23, 25, 26, 28]
  end

  # `{line, number}` for every line that can hold SQL or a query binding:
  # a line inside a heredoc that is not a `@doc` / `@moduledoc`, a quoted
  # line with an SQL keyword (any case) or a name inside a call in the
  # string (`"COALESCE(mtime, 0)"`), and any non-comment line (for bindings, which
  # the caller matches separately).
  defp sql_lines(src) do
    sql_word = ~r/\b(SELECT|UPDATE|INSERT|WHERE|SET|FROM)\b/i
    # A name inside a call within ONE string literal (`"COALESCE(mtime, 0)"`),
    # not a call that merely follows a string (`{"x-mtime", f(mtime)}`).
    sql_call = ~r/\w\(.*\b(mtime|ctime)\b/

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
            in_literal?(line, sql_call) -> {{line, n}, :code}
            Regex.match?(~r/(?<![A-Za-z_.])[a-z]\.(mtime|ctime)\b/, line) -> {{line, n}, :code}
            true -> {nil, :code}
          end
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp in_literal?(line, re) do
    ~r/"(?:[^"\\]|\\.)*"/
    |> Regex.scan(line)
    |> Enum.any?(fn [lit] -> Regex.match?(re, lit) end)
  end
end
