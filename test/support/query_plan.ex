defmodule Engram.QueryPlan do
  @moduledoc """
  Test helper: the plan Postgres would use for a statement the app really sends.

  Pair it with `Engram.QueryRecorder`: record a public call, pick the statement,
  then ask which index serves it. A partial index only helps when the query's
  WHERE implies the index predicate, which a behaviour test cannot see.

  The plan is the GENERIC one (`plan_cache_mode = force_generic_plan`), with
  every parameter bound to NULL. A one-off EXPLAIN inlines the values, so a
  parameter can appear to match a partial predicate that a reused prepared
  statement never would. `enable_seqscan = off` because a test table is tiny
  and a seq scan would win on cost alone; what is asserted is whether an index
  CAN serve the statement.
  """

  alias Engram.Repo

  @doc """
  The generic plan for `sql`. `analyze:` names tables to ANALYZE first, so a
  test that seeded rows gets real statistics instead of the empty-table guess.
  `bitmapscan: false` rules out a bitmap scan of a DIFFERENT index, for a
  statement whose index scan the planner costs as several descents (`= ANY($n)`
  is costed as 10) and a tiny test table makes one bitmap over the whole
  vault cheaper. The question stays the same: can the named index serve it.
  """
  @spec generic_plan(String.t(), keyword()) :: String.t()
  def generic_plan(sql, opts \\ []) do
    nulls =
      ~r/\$(\d+)/
      |> Regex.scan(sql, capture: :all_but_first)
      |> Enum.map(fn [n] -> String.to_integer(n) end)
      |> Enum.max(fn -> 0 end)
      |> then(&List.duplicate("NULL", &1))

    args = if nulls == [], do: "", else: "(" <> Enum.join(nulls, ", ") <> ")"
    name = "plan_#{System.unique_integer([:positive])}"

    {:ok, text} =
      Repo.transaction(fn ->
        for table <- Keyword.get(opts, :analyze, []), do: Repo.query!("ANALYZE #{table}")
        Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
        Repo.query!("SET LOCAL enable_seqscan = off")

        unless Keyword.get(opts, :bitmapscan, true),
          do: Repo.query!("SET LOCAL enable_bitmapscan = off")

        Repo.query!("PREPARE #{name} AS " <> sql)

        try do
          Repo.query!("EXPLAIN EXECUTE #{name}#{args}").rows
          |> List.flatten()
          |> Enum.join("\n")
        after
          Repo.query!("DEALLOCATE #{name}")
        end
      end)

    text
  end

  @doc """
  The statements the calling process recorded whose SQL reads `table`, in
  order. The recorder's telemetry handler sees every process's queries, so an
  async sibling test's reads would otherwise land in this list.
  """
  @spec reading([map()], String.t()) :: [String.t()]
  def reading(queries, table) do
    me = self()
    for %{sql: sql, pid: ^me} <- queries, sql =~ ~s(FROM "#{table}"), do: sql
  end
end
