defmodule Engram.WindowedReads do
  @moduledoc """
  Test oracle for #2276: does a statement bound the rows it READS from a
  table to one id window, or only the rows it returns?

  A statement passes when every source of `table` in it (each `FROM`,
  `JOIN` or `UPDATE` of the table, subqueries and CTEs included) is
  either:

    * the window read itself (`Engram.Backfill.IdWindows`): the WHERE holds
      only the keyset comparison on the key, plus an optional `user_id`
      equality and `display_ct IS NOT NULL`, ordered by the key, with a
      `LIMIT $n` of at most `window`; or
    * confined to a window by its key, ANDed into its WHERE (no `OR` at any
      level between the term and its statement): `key = ANY($n)` with `$n` a
      list of at most `window` ids, `key = ANY(ARRAY(<subquery>))` or
      `key IN (<subquery>)` (the subquery's own sources are checked too), or
      a join on the key to a CTE.

  "The next N rows MATCHING a predicate" (`WHERE <predicate> AND id > $a
  ORDER BY id LIMIT $n`) fails: its LIMIT bounds rows returned, not read.
  """

  @keys ~w(id vault_id point_id)

  @doc "True when `sql` reads `table` only inside one window of `window` keys."
  def windowed?(sql, params, table, window) do
    sources = sources(sql, table)

    sources == [] or window_read?(sql, params, window) or
      Enum.all?(sources, &confined?(sql, params, &1, window, table))
  end

  # Every alias `table` is read under: `{alias, start_offset}`. A bare table
  # with no alias is read under its own name.
  defp sources(sql, table) do
    ~r/\b(?:FROM|JOIN|UPDATE)\s+"?#{table}"?(?:\s+AS)?(?:\s+("?\w+"?))?/i
    |> Regex.scan(sql, return: :index)
    |> Enum.map(fn
      [{start, _} | rest] ->
        name =
          case rest do
            [{s, l}] when s >= 0 -> sql |> binary_part(s, l) |> String.trim("\"")
            _ -> nil
          end

        alias = if name == nil or keyword?(name), do: table, else: name
        {alias, start}
    end)
  end

  defp keyword?(word),
    do:
      String.upcase(word) in ~w(WHERE LEFT RIGHT INNER OUTER JOIN ON SET ORDER LIMIT GROUP FOR AS)

  # The IdWindows window read, whole statement.
  defp window_read?(sql, params, window) do
    re =
      ~r/^SELECT (\w+)\."(\w+)" FROM "\w+" AS \1 WHERE (.+) ORDER BY \1\."\2" LIMIT \$(\d+)$/

    with [_, a, key, where, limit] <- Regex.run(re, String.trim(sql)),
         true <- key in @keys,
         true <- param(params, limit) <= window do
      where
      |> String.split(" AND ")
      |> Enum.map(&strip_parens/1)
      |> Enum.all?(fn term ->
        term =~ ~r/^#{a}\."#{key}" > \$\d+(::\w+)?$/ or
          term =~ ~r/^#{a}\."user_id" = \$\d+(::\w+)?$/ or
          term =~ ~r/^NOT \(#{a}\."display_ct" IS NULL\)$/
      end)
    else
      _ -> false
    end
  end

  defp strip_parens("(" <> rest = term) do
    if String.ends_with?(rest, ")") and balanced?(String.slice(rest, 0..-2//1)),
      do: strip_parens(String.slice(rest, 0..-2//1)),
      else: term
  end

  defp strip_parens(term), do: term

  defp balanced?(s) do
    Enum.reduce_while(String.graphemes(s), 0, fn
      "(", d -> {:cont, d + 1}
      ")", 0 -> {:halt, -1}
      ")", d -> {:cont, d - 1}
      _, d -> {:cont, d}
    end) == 0
  end

  # The source's key is pinned to a window, ANDed all the way out.
  defp confined?(sql, params, {alias, _start}, window, table) do
    keys =
      Map.get(%{"vault_index_states" => "vault_id", "chunk_points" => "point_id"}, table, "id")

    # An aliased source must name its alias; a bare one, an unqualified key.
    col =
      if alias == table,
        do: ~s/(?:\\b#{table}\\.|(?<![.\\w"]))"?(?:#{keys})"?/,
        else: ~s/\\b#{alias}\\."?(?:#{keys})"?/

    listed =
      ~r/#{col} = ANY\(\$(\d+)/
      |> Regex.scan(sql, return: :index, capture: :all)
      |> Enum.any?(fn [{pos, _}, {s, l}] ->
        ids = param(params, binary_part(sql, s, l))
        is_list(ids) and ids != [] and length(ids) <= window and anded?(sql, pos)
      end)

    subquery =
      ~r/#{col} (?:= ANY\(ARRAY\(|IN \(SELECT )/
      |> Regex.scan(sql, return: :index)
      |> Enum.any?(fn [{pos, _}] -> anded?(sql, pos) end)

    listed or subquery or cte_join?(sql, alias)
  end

  # `x."id" = alias."id"` where x reads a CTE (`WITH "name" AS`).
  defp cte_join?(sql, alias) do
    ctes = for [_, n] <- Regex.scan(~r/WITH "?(\w+)"? AS/i, sql), do: n

    Enum.any?(ctes, fn cte ->
      case Regex.run(~r/\b(?:FROM|JOIN)\s+"?#{cte}"?\s+AS\s+(\w+)/i, sql) do
        [_, x] ->
          sql =~ ~r/\b#{x}\."id" = #{alias}\."id"/ or sql =~ ~r/\b#{alias}\."id" = #{x}\."id"/

        nil ->
          false
      end
    end)
  end

  # No `OR` at depth 0 of any group enclosing `pos`, out to its statement
  # (a group opening with SELECT is a subquery: its own statement).
  defp anded?(sql, pos) do
    case enclosing(sql, pos) do
      nil ->
        not where_or?(sql)

      {open, close} ->
        group = binary_part(sql, open + 1, close - open - 1)

        cond do
          group =~ ~r/^\s*SELECT\b/i -> not where_or?(group)
          top_level_or?(group) -> false
          true -> anded?(sql, open)
        end
    end
  end

  # The innermost `(...)` around `pos`, as `{open, close}` offsets.
  defp enclosing(sql, pos) do
    with open when open != nil <- open_before(sql, pos - 1, 0) do
      {open, close_after(sql, open + 1, 0)}
    end
  end

  defp open_before(_sql, i, _depth) when i < 0, do: nil

  defp open_before(sql, i, depth) do
    case :binary.at(sql, i) do
      ?( when depth == 0 -> i
      ?( -> open_before(sql, i - 1, depth - 1)
      ?) -> open_before(sql, i - 1, depth + 1)
      _ -> open_before(sql, i - 1, depth)
    end
  end

  defp close_after(sql, i, depth) do
    case :binary.at(sql, i) do
      ?) when depth == 0 -> i
      ?) -> close_after(sql, i + 1, depth - 1)
      ?( -> close_after(sql, i + 1, depth + 1)
      _ -> close_after(sql, i + 1, depth)
    end
  end

  # An `OR` at depth 0 of a statement's WHERE (its select list may hold
  # any expression).
  defp where_or?(statement) do
    case statement |> depth0() |> String.split(~r/\bWHERE\b/i, parts: 2) do
      [_, where] -> where =~ ~r/\bOR\b/i
      _ -> false
    end
  end

  defp top_level_or?(s), do: depth0(s) =~ ~r/\bOR\b/i

  # The text of `s` outside every parenthesized group.
  defp depth0(s) do
    s
    |> String.graphemes()
    |> Enum.reduce({0, []}, fn
      "(", {d, acc} -> {d + 1, acc}
      ")", {d, acc} -> {d - 1, acc}
      c, {0, acc} -> {0, [c | acc]}
      _, acc -> acc
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp param(params, i) when is_binary(i), do: Enum.at(params, String.to_integer(i) - 1)
end
