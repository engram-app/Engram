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

  `fresh: true` makes the plan depend only on THIS test's rows. Without it,
  the planner also sees the physical state earlier tests in the same
  partition left behind, which the sandbox rollback does not undo: dead
  index pages from rolled-back inserts (index cost reads the physical size),
  heap pages those rows freed (this test's rows land scattered in them, so
  the ANALYZE correlation varies), and the visibility map of vacuumed pages.
  A plan test flipped that way when new test files reshuffled partitions
  (DrainTest and BackfillCrdtHeadIndexTest on #2424). `fresh` rewrites each
  `analyze:` table with `CLUSTER ... USING` its primary key inside the
  test's transaction (rolled back with it): a new heap and new indexes
  holding only this test's rows, in key order, as a table written in uuidv7
  order is in prod. CLUSTER holds an ACCESS EXCLUSIVE lock to the end of
  the test: use it from `async: false` tests only.

  `seqscan: true` keeps seq scans on, to ask which plan Postgres picks.
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
        fresh? = Keyword.get(opts, :fresh, false)

        for table <- Keyword.get(opts, :analyze, []) do
          if fresh?, do: cluster_on_pkey!(table)
          Repo.query!("ANALYZE #{table}")
        end

        Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")

        unless Keyword.get(opts, :seqscan, false),
          do: Repo.query!("SET LOCAL enable_seqscan = off")

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
  The custom and the generic plan of the statement `fun` sends: runs `fun`
  `runs` times, takes the last statement of this process whose SQL matches
  `pattern`, and returns `%{custom:, generic:}`.

    * `custom`: a one-off parameterised EXPLAIN with the recorded values,
      the plan each of the first 5 executions of a prepared statement gets;
    * `generic`: `generic_plan/2` (a fresh `PREPARE` under
      `force_generic_plan`, seq scans left on), the plan with no values a
      6th or later execution may switch to.

  Neither reads the prepared statement the runs built, so the runs do not
  change what is asserted: they exercise the call as prod repeats it and
  record its real SQL and values. What asserting BOTH plans proves is
  that the statement reads the right index whichever plan Postgres picks
  after the 5th execution; it does not show which one it picked.
  """
  @spec after_runs((-> term()), Regex.t(), pos_integer()) :: %{
          custom: String.t(),
          generic: String.t()
        }
  def after_runs(fun, pattern, runs \\ 7) do
    %{sql: sql, params: params} =
      Enum.reduce(1..runs, nil, fn _, _ ->
        {_, queries} = Engram.QueryRecorder.record(fun)
        me = self()
        queries |> Enum.filter(&(&1.pid == me and &1.sql =~ pattern)) |> List.last()
      end) || flunk("no statement matched #{inspect(pattern)}")

    custom = Repo.query!("EXPLAIN " <> sql, params).rows |> List.flatten() |> Enum.join("\n")
    %{custom: custom, generic: generic_plan(sql, seqscan: true)}
  end

  defp flunk(message), do: raise(ExUnit.AssertionError, message: message)

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

  defp cluster_on_pkey!(table) do
    %{rows: [[pkey]]} =
      Repo.query!(
        "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "WHERE i.indrelid = $1::text::regclass AND i.indisprimary",
        [table]
      )

    Repo.query!(~s(CLUSTER "#{table}" USING "#{pkey}"))
  end
end
