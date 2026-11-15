defmodule Mix.Tasks.Engram.MigrationDrops do
  @shortdoc "Extracts dropped columns and tables from an Ecto migration file"
  @moduledoc """
  AST-walks one or more Ecto migration files and prints the columns and
  tables they drop. Used by the `migration-gates` CI job to
  decide what to grep `lib/` for.

  ## Usage

      mix engram.migration_drops priv/repo/migrations/20260603120000_drop_legacy.exs

  Output format (one per line):

      column users legacy_flag
      table  legacy_audit
      rawsql priv/repo/migrations/20260603120000_drop_legacy.exs

  A column or table **rename** counts as dropping the old name, because the
  previous release (still running mid-deploy) reads it. Only the migration's
  up direction counts: `def down` bodies are ignored, so the reversal of an
  additive migration is not mistaken for a drop. Raw SQL counts wherever its
  string literal sits (`execute/1`, or a list handed to a helper such as
  `LockTimeoutRetry.with_lock_timeout/2`); `@moduledoc`/`@doc` prose does
  not. A string that is exactly one `ALTER TABLE <t> DROP COLUMN <c>` or
  `DROP TABLE <t>` maps to its identifiers. Any other string naming a
  `DROP COLUMN|TABLE` cannot be analyzed; it is reported as `rawsql` so the
  CI gate can ask for Ecto's `remove`/`drop` or a `# safety_assured:` reason.

  File-level magic comment escape:

      # safety_assured: "<justification>"

  When present as a top-of-file comment, the migration is skipped entirely
  (extraction returns empty). The reviewer trusts the justification.
  """

  use Mix.Task

  # One whole statement naming one unqualified identifier (optionally quoted).
  @ident ~S{"?([A-Za-z_][A-Za-z0-9_]*)"?}
  @tail ~S{(?:\s+(?:CASCADE|RESTRICT))?\s*;?\s*$}
  @drop_column Regex.compile!(
                 ~S{^\s*ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?} <>
                   @ident <> ~S{\s+DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?} <> @ident <> @tail,
                 "i"
               )
  @drop_table Regex.compile!(
                ~S{^\s*DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?} <> @ident <> @tail,
                "i"
              )

  @doc false
  def run(paths) do
    Enum.each(paths, fn path ->
      %{columns: cols, tables: tables} = result = extract(path)
      Enum.each(cols, fn {table, col} -> IO.puts("column #{table} #{col}") end)
      Enum.each(tables, fn t -> IO.puts("table #{t}") end)
      if Map.get(result, :raw_sql), do: IO.puts("rawsql #{path}")
    end)
  end

  @doc """
  Returns a map with `:columns` (list of `{table_name, column_name}` strings)
  and `:tables` (list of table_name strings) dropped by the migration at
  `path`. If the file carries a top-level `# safety_assured: ...` comment,
  returns empty lists. `raw_sql: true` is added only when an up-direction
  string holds a `DROP COLUMN` or `DROP TABLE` it cannot map to identifiers.
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
    # Scan the whole file (not just first 20 lines): a long @moduledoc or
    # copyright header can push the magic comment past any line limit.
    # Regex requires opening quote + at least one non-quote character +
    # closing quote — `# safety_assured: ""` or `# safety_assured: "` does
    # NOT bypass. The justification must be a non-empty string.
    Regex.match?(~r/^\s*#\s*safety_assured:\s*"[^"\n]+"\s*$/m, source)
  end

  defp do_extract(ast) do
    # Only the up direction counts: a `def down` that removes what `up` added
    # is the ordinary reversal of an additive migration, not a drop. That
    # includes its body moved into a helper (`def down, do: run_down(repo())`).
    # Doc attributes are prose: a moduledoc explaining a drop is not one.
    ast =
      Macro.prewalk(ast, fn
        {kind, _, [{name, _, _} | _]} = node when kind in [:def, :defp] and is_atom(name) ->
          if down_fun?(name), do: nil, else: node

        {:@, _, [{attr, _, _}]} when attr in [:moduledoc, :doc] ->
          nil

        node ->
          node
      end)

    # Design note: this walks the AST twice on :alter subtrees by design.
    #
    # The outer `Macro.prewalk` invokes `visit/2` on every node. The `:alter`
    # clause MANUALLY descends into its do-block via `Enum.reduce + Macro.prewalk`
    # so it can carry `current_table` as accumulator state — without that
    # context, a bare `remove(:col)` doesn't know which table it belongs to.
    #
    # After the `:alter` clause returns, the outer prewalk also descends into
    # those same children. It will hit the `:remove`/`:remove_if_exists` clause
    # again, but with `current_table: nil` (the inner walk's value was scoped
    # to the alter block and reset on exit). The `not is_nil(tbl)` guard on
    # those clauses no-ops the outer visit. Net effect: each remove is
    # captured exactly once, by the inner walk.
    #
    # If you change either the outer prewalk OR the :remove/:remove_if_exists
    # guard, run the test suite — the safety here is enforced ONLY by that
    # guard, not by walk structure.
    {_, acc} =
      Macro.prewalk(ast, %{columns: [], tables: [], current_table: nil, raw_sql: false}, fn node,
                                                                                            acc ->
        {node, visit(node, acc)}
      end)

    # A string inside an alter block is visited by both walks: count it once.
    result = %{
      columns: acc.columns |> Enum.reverse() |> Enum.uniq(),
      tables: acc.tables |> Enum.reverse() |> Enum.uniq()
    }

    if acc.raw_sql, do: Map.put(result, :raw_sql, true), else: result
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

  # `rename table(:t), :old, to: :new` drops the name the previous release reads.
  defp visit({:rename, _, [{:table, _, [tbl | _]}, col, _opts]}, acc)
       when (is_atom(tbl) or is_binary(tbl)) and is_atom(col) do
    table_name = if is_atom(tbl), do: Atom.to_string(tbl), else: tbl
    %{acc | columns: [{table_name, Atom.to_string(col)} | acc.columns]}
  end

  # `rename table(:old), to: table(:new)`
  defp visit({:rename, _, [{:table, _, [tbl | _]}, _opts]}, acc)
       when is_atom(tbl) or is_binary(tbl) do
    table_name = if is_atom(tbl), do: Atom.to_string(tbl), else: tbl
    %{acc | tables: [table_name | acc.tables]}
  end

  # Any up-direction string literal: `execute("...")` or a statement list
  # handed to a helper. One single-target drop maps to its identifiers;
  # anything else naming a drop is flagged rather than silently passed.
  defp visit(sql, acc) when is_binary(sql) do
    cond do
      match = Regex.run(@drop_column, sql, capture: :all_but_first) ->
        [table, col] = match
        %{acc | columns: [{table, col} | acc.columns]}

      match = Regex.run(@drop_table, sql, capture: :all_but_first) ->
        %{acc | tables: [hd(match) | acc.tables]}

      Regex.match?(~r/\bdrop\s+(column|table)\b/i, sql) ->
        %{acc | raw_sql: true}

      true ->
        acc
    end
  end

  defp visit(_node, acc), do: acc

  # `down`, or a helper it delegates to (`run_down`, `do_down`).
  defp down_fun?(name), do: name == :down or String.ends_with?(Atom.to_string(name), "_down")
end
