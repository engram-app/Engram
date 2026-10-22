defmodule Engram.QueryRecorder do
  @moduledoc "Test helper: records every Repo query a function issues, with its Engram caller."

  # The handler forwards every process's queries, so under a busy async
  # suite a 50 ms quiet gap may never come: two tests sat in this loop for
  # the whole 60 s test timeout (#2151 CI). The recorded function's own
  # queries were sent before it returned; the gap only waits for stragglers,
  # so it is capped.
  @drain_max_ms 1_000

  def record(fun) do
    me = self()
    id = "query-recorder-#{System.unique_integer([:positive])}"

    :telemetry.attach(id, [:engram, :repo, :query], &__MODULE__.handle/4, me)

    try do
      result = fun.()
      {result, drain([], System.monotonic_time(:millisecond) + @drain_max_ms)}
    after
      :telemetry.detach(id)
    end
  end

  defp poller_query?(sql) do
    sql =~ ~r/FROM "public"."oban_jobs".*GROUP BY/s or
      (sql =~ ~r/FROM "rebuild_ledger"/ and from_ledger_poller?())
  end

  # Only the poller's read: a request path that reads the ledger still counts.
  defp from_ledger_poller? do
    {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)
    Enum.any?(st, &match?({Engram.PromEx.Indexing, :execute_rebuild_ledger, _, _}, &1))
  end

  @doc false
  def handle(_event, _measurements, meta, pid) do
    # Telemetry pollers fire on a timer in an unrelated process and would make
    # counts flap by one: the oban_jobs gauge and the v5 rebuild ledger gauge
    # (`Engram.PromEx.Indexing.execute_rebuild_ledger/0`).
    unless poller_query?(meta.query) do
      {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)
      # `pid`: the process that ran the query, so an async test can keep only
      # its own (the handler sees every process's queries).
      send(
        pid,
        {:recorded_query,
         %{source: meta[:source], sql: meta.query, caller: caller(st), pid: self()}}
      )
    end
  end

  defp caller(st) do
    st
    |> Enum.filter(fn {mod, _, _, _} ->
      name = inspect(mod)
      String.starts_with?(name, "Engram") and name not in ["Engram.Repo", "Engram.QueryRecorder"]
    end)
    |> Enum.take(3)
    |> Enum.map_join(" < ", fn {mod, f, a, loc} ->
      "#{inspect(mod)}.#{f}/#{if is_list(a), do: length(a), else: a}:#{loc[:line]}"
    end)
  end

  defp drain(acc, deadline) do
    wait = min(50, max(0, deadline - System.monotonic_time(:millisecond)))

    receive do
      {:recorded_query, q} -> drain([q | acc], deadline)
    after
      wait -> Enum.reverse(acc)
    end
  end

  @doc """
  The top-level transactions `pid` ran, each as the list of SQL statements
  between its `begin` and `commit`. A nested `Repo.transaction` logs no
  begin/commit of its own, so its statements fold into the outer one.
  Statements outside any transaction are dropped.
  """
  def transactions(queries, pid \\ self()) do
    queries
    |> Enum.filter(&(&1.pid == pid))
    |> Enum.reduce({[], nil}, fn
      %{sql: "begin"}, {done, nil} -> {done, []}
      %{sql: "commit"}, {done, open} when is_list(open) -> {[Enum.reverse(open) | done], nil}
      %{sql: sql}, {done, open} when is_list(open) -> {done, [sql | open]}
      _outside, acc -> acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def format(queries) do
    queries
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {q, i} ->
      "#{i}. [#{q.source || "-"}] #{q.sql |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)}\n     <- #{q.caller}"
    end)
  end
end
