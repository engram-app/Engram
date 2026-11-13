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
  order is in prod. The plan runs in a savepoint rolled back after it, so
  the rewrite and its ACCESS EXCLUSIVE lock end with the plan; use it from
  `async: false` tests only all the same.

  `seqscan: true` keeps seq scans on, to ask which plan Postgres picks.

  `all_visible: true` tells the planner every heap page of each `analyze:`
  table is all-visible (`pg_class.relallvisible`, rolled back with the
  plan), as a vacuumed prod table mostly is. `fresh` leaves the visibility
  map empty, so an index-only scan would be costed like a heap read and a
  covering index would look no better than any other.
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

    rolled_back(fn ->
      fresh? = Keyword.get(opts, :fresh, false)

      for table <- Keyword.get(opts, :analyze, []) do
        if fresh?, do: fresh!(table), else: Repo.query!("ANALYZE #{table}")

        # Rolled back with the savepoint (catalog rows are transactional).
        if Keyword.get(opts, :all_visible, false),
          do:
            Repo.query!(
              "UPDATE pg_class SET relallvisible = relpages WHERE oid = '#{table}'::regclass"
            )
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
        # Not `query!`: after a failed EXPLAIN the transaction is aborted, and
        # a DEALLOCATE error would hide the EXPLAIN's own.
        Repo.query("DEALLOCATE #{name}")
      end
    end)
  end

  @doc """
  The custom and the generic plan of the statement `fun` sends: runs `fun`
  `runs:` times (default 7, past the 5 custom plans Postgres tries first),
  takes the last statement of this process whose SQL matches `pattern`, and
  returns `%{custom:, generic:}`.

    * `custom`: a one-off parameterised EXPLAIN with the recorded values,
      the plan each of the first 5 executions of a prepared statement gets;
    * `generic`: `generic_plan/2` (a fresh `PREPARE` under
      `force_generic_plan`, seq scans left on), the plan with no values a
      6th or later execution may switch to.

  Neither reads the prepared statement the runs built: asserting BOTH plans
  proves the statement reads the right index whichever plan Postgres picks
  after the 5th execution, not which one it picked. `seqscan: false` plans
  both with seq scans off, for a statement the planner costs as matching
  most of the table: on a test-sized table a seq scan and sort is then the
  cheaper plan, and the verdict turns on statistics other tests left behind
  (`subscriptions` vacuumed or ANALYZEd while empty costs a per-row EXISTS
  at 0). It then asks whether the index CAN serve each plan.
  `no_generic: true` also asks that: it fails if any named statement with this SQL ran on a generic
  plan (`pg_prepared_statements.generic_plans`), for a statement the app
  must run unnamed (`Engram.Notes.Keys.lookup?/1`), where only the 7 runs
  can show it.
  """
  @spec after_runs((-> term()), Regex.t(), keyword()) :: %{
          custom: String.t(),
          generic: String.t()
        }
  def after_runs(fun, pattern, opts \\ []) do
    %{sql: sql, params: params} =
      Enum.reduce(1..Keyword.get(opts, :runs, 7), nil, fn _, _ ->
        {_, queries} = Engram.QueryRecorder.record(fun)
        me = self()
        queries |> Enum.filter(&(&1.pid == me and &1.sql =~ pattern)) |> List.last()
      end) || flunk("no statement matched #{inspect(pattern)}")

    if Keyword.get(opts, :no_generic, false) do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT coalesce(sum(generic_plans), 0)::int FROM pg_prepared_statements WHERE statement = $1",
          [sql]
        )

      if n > 0, do: flunk("ran on a generic plan #{n} times:\n#{sql}")
    end

    seqscan? = Keyword.get(opts, :seqscan, true)
    %{custom: custom_plan(sql, params, seqscan?), generic: generic_plan(sql, seqscan: seqscan?)}
  end

  defp custom_plan(sql, params, seqscan?) do
    rolled_back(fn ->
      unless seqscan?, do: Repo.query!("SET LOCAL enable_seqscan = off")
      Repo.query!("EXPLAIN " <> sql, params).rows |> List.flatten() |> Enum.join("\n")
    end)
  end

  # `fun`'s result, in a savepoint rolled back after it: its SET LOCALs (and
  # a `fresh` CLUSTER, ANALYZE and their locks) end with the plan instead of
  # lasting to the end of the test. A raw SAVEPOINT, not `Repo.rollback/1`:
  # that would mark an enclosing Ecto transaction (`Repo.with_tenant!/2`) as
  # rolling back too. Inside `Repo.transaction/1`, because the sandbox wraps
  # (and releases) each statement run outside one in its own savepoint.
  defp rolled_back(fun) do
    savepoint = "query_plan_#{System.unique_integer([:positive])}"

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT #{savepoint}")

        try do
          fun.()
        after
          Repo.query!("ROLLBACK TO SAVEPOINT #{savepoint}")
          Repo.query!("RELEASE SAVEPOINT #{savepoint}")
        end
      end)

    result
  end

  defp flunk(message), do: raise(ExUnit.AssertionError, message: message)

  @doc """
  How prod runs `sql`: as `engram_app` with `user_id`'s tenant set (FORCE
  RLS on), `EXPLAIN (ANALYZE, BUFFERS)` with the recorded `params`, as a
  custom plan and as a forced generic plan (`PREPARE` under
  `plan_cache_mode = force_generic_plan`, then `EXECUTE` with the same
  values), after `DISCARD PLANS`, with seq scans off (a Seq Scan left in
  the plan means no index can serve it). Returns `%{custom:, generic:}` plan texts.

  A plan read as the suite's superuser skips RLS, so it cannot show a qual
  the security barrier keeps from driving an index: under RLS a qual that
  applies a non-leakproof function (`byteacat`, `uuid_send`, most casts) to
  a column is evaluated only after the policy's own quals, so it is never an
  index condition and the scan falls back to the tenant's index
  (`docs/context/rls-leakproof-index-quals.md`). Read-only statements only:
  the run rolls back, but an EXPLAIN ANALYZE executes the statement.
  """
  @spec rls_plans(Ecto.UUID.t(), String.t(), list()) :: %{custom: String.t(), generic: String.t()}
  def rls_plans(user_id, sql, params) do
    name = "rls_plan_#{System.unique_integer([:positive])}"
    explain = "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) "

    rolled_back(fn ->
      Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
      Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user_id])
      Repo.query!("DISCARD PLANS")
      # A test table is a page or two, where a seq scan wins on cost alone.
      # Off, a Seq Scan still in the plan means no index can serve it.
      Repo.query!("SET LOCAL enable_seqscan = off")
      custom = plan_text(Repo.query!(explain <> sql, params))

      Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")
      Repo.query!("PREPARE #{name} AS " <> sql)

      try do
        # EXECUTE takes no protocol parameters: the values go in as literals
        # of the types the PREPARE inferred.
        %{rows: [[types]]} =
          Repo.query!(
            "SELECT parameter_types::text[] FROM pg_prepared_statements WHERE name = $1",
            [name]
          )

        args = Enum.zip_with(params, types, &literal/2)
        execute = if args == [], do: name, else: "#{name}(#{Enum.join(args, ", ")})"
        %{custom: custom, generic: plan_text(Repo.query!(explain <> "EXECUTE " <> execute))}
      after
        Repo.query("DEALLOCATE #{name}")
      end
    end)
  end

  defp literal(nil, type), do: "NULL::#{type}"

  defp literal(list, type) when is_list(list) do
    elem_type = String.trim_trailing(type, "[]")
    "ARRAY[#{Enum.map_join(list, ", ", &literal(&1, elem_type))}]::#{type}"
  end

  defp literal(<<_::128>> = uuid, "uuid"), do: "'#{Ecto.UUID.load!(uuid)}'::uuid"
  defp literal(bin, "bytea") when is_binary(bin), do: "'\\x#{Base.encode16(bin)}'::bytea"
  defp literal(bin, type) when is_binary(bin), do: "'#{String.replace(bin, "'", "''")}'::#{type}"
  defp literal(%DateTime{} = t, type), do: "'#{DateTime.to_iso8601(t)}'::#{type}"
  defp literal(%NaiveDateTime{} = t, type), do: "'#{NaiveDateTime.to_iso8601(t)}'::#{type}"
  defp literal(value, type) when is_number(value) or is_boolean(value), do: "#{value}::#{type}"

  @doc "The top node's `shared hit + read` buffer count of an `rls_plans/3` plan."
  @spec buffers(String.t()) :: non_neg_integer()
  def buffers(plan) do
    case Regex.run(~r/Buffers: shared ([^\n]+)/, plan) do
      [_, counts] ->
        ~r/(?:hit|read)=(\d+)/
        |> Regex.scan(counts)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)
        |> Enum.sum()

      nil ->
        0
    end
  end

  defp plan_text(%{rows: rows}), do: rows |> List.flatten() |> Enum.join("\n")

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

  @doc """
  `table` rewritten as `fresh: true` does (CLUSTER on its primary key, see
  `generic_plan/2`), then ANALYZEd: statistics and physical layout from this
  test's rows only, for a test that reads a plan some other way (a recorded
  custom plan). Inside the test's transaction, rolled back with it. CLUSTER
  holds an ACCESS EXCLUSIVE lock to the end of the test: `async: false` only.
  """
  @spec fresh!(String.t()) :: :ok
  def fresh!(table) do
    cluster_on_pkey!(table)
    Repo.query!("ANALYZE #{table}")
    :ok
  end

  @doc """
  The visibility map of `tables` counted as fully set (`relallvisible =
  relpages`), for a test that asserts an index-only scan. A sandbox cannot
  VACUUM, so no page of a test's rows is all-visible and the planner costs
  every index-only scan as a heap fetch per row: it then ties with a plain
  index scan of another index at the cost floor, and which one wins turns
  on statistics earlier tests left behind (CI drew `note_attrs_pkey` over
  the field catalog's partial index that way). Prod's cold rows are
  all-visible. Run it after the ANALYZE (`fresh!/1`), which resets the
  count. It changes only the planner's cost estimate (an UPDATE of
  `pg_class.relallvisible` inside the test's transaction, rolled back with
  it), never the visibility map itself or any data: the executor still
  checks each heap page.
  """
  @spec all_visible!([String.t()]) :: :ok
  def all_visible!(tables) do
    Repo.query!(
      "UPDATE pg_class SET relallvisible = relpages " <>
        "WHERE relname = ANY($1) AND relnamespace = 'public'::regnamespace",
      [tables]
    )

    :ok
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
