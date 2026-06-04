defmodule Mix.Tasks.Engram.MigrationDrops do
  @shortdoc "Extracts dropped columns and tables from an Ecto migration file"
  @moduledoc """
  AST-walks one or more Ecto migration files and prints the columns and
  tables they drop. Used by the `contract-phase-references` CI gate to
  decide what to grep `lib/` for.

  ## Usage

      mix engram.migration_drops priv/repo/migrations/20260603120000_drop_legacy.exs

  Output format (one per line):

      column users legacy_flag
      table  legacy_audit

  File-level magic comment escape:

      # safety_assured: "<justification>"

  When present as a top-of-file comment, the migration is skipped entirely
  (extraction returns empty). The reviewer trusts the justification.
  """

  use Mix.Task

  @doc false
  def run(paths) do
    Enum.each(paths, fn path ->
      %{columns: cols, tables: tables} = extract(path)
      Enum.each(cols, fn {table, col} -> IO.puts("column #{table} #{col}") end)
      Enum.each(tables, fn t -> IO.puts("table #{t}") end)
    end)
  end

  @doc """
  Returns a map with `:columns` (list of `{table_name, column_name}` strings)
  and `:tables` (list of table_name strings) dropped by the migration at
  `path`. If the file carries a top-level `# safety_assured: ...` comment,
  returns empty lists.
  """
  def extract(path) do
    source = File.read!(path)

    if safety_assured?(source) do
      %{columns: [], tables: []}
    else
      case Code.string_to_quoted(source) do
        {:ok, ast} ->
          do_extract(ast)

        {:error, {meta, msg, token}} ->
          line = meta[:line] || "?"
          Mix.raise("#{path}: syntax error at line #{line} - #{msg}#{token}")
      end
    end
  end

  defp safety_assured?(source) do
    source
    |> String.split("\n")
    |> Enum.take(20)
    |> Enum.any?(&Regex.match?(~r/^\s*#\s*safety_assured:\s*"/, &1))
  end

  defp do_extract(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{columns: [], tables: [], current_table: nil}, fn node, acc ->
        {node, visit(node, acc)}
      end)

    %{columns: Enum.reverse(acc.columns), tables: Enum.reverse(acc.tables)}
  end

  # `alter table(:foo) do ... end` — push :foo as the current table so nested
  # `remove(:bar)` knows which table the column belongs to.
  defp visit(
         {:alter, _, [{:table, _, [tbl | _]} | rest]} = _node,
         acc
       )
       when is_atom(tbl) or is_binary(tbl) do
    table_name = if is_atom(tbl), do: Atom.to_string(tbl), else: tbl
    inner_acc = %{acc | current_table: table_name}

    inner_acc =
      Enum.reduce(rest, inner_acc, fn arg, a ->
        {_, a2} = Macro.prewalk(arg, a, fn n, a3 -> {n, visit(n, a3)} end)
        a2
      end)

    %{inner_acc | current_table: acc.current_table}
  end

  # `remove(:col)` or `remove(:col, type, opts)` inside an alter block.
  defp visit({fun, _, [col | _]}, %{current_table: tbl} = acc)
       when fun in [:remove, :remove_if_exists] and is_atom(col) and not is_nil(tbl) do
    %{acc | columns: [{tbl, Atom.to_string(col)} | acc.columns]}
  end

  # `drop(table(:foo))` or `drop_if_exists(table(:foo))` — top-level table drop.
  defp visit({fun, _, [{:table, _, [tbl | _]}]}, acc)
       when fun in [:drop, :drop_if_exists] and (is_atom(tbl) or is_binary(tbl)) do
    table_name = if is_atom(tbl), do: Atom.to_string(tbl), else: tbl
    %{acc | tables: [table_name | acc.tables]}
  end

  defp visit(_node, acc), do: acc
end
