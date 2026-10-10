defmodule Engram.QueryRecorder do
  @moduledoc "Test helper: records every Repo query a function issues, with its Engram caller."

  def record(fun) do
    me = self()
    id = "query-recorder-#{System.unique_integer([:positive])}"

    :telemetry.attach(id, [:engram, :repo, :query], &__MODULE__.handle/4, me)

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def handle(_event, _measurements, meta, pid) do
    # The telemetry poller's oban_jobs gauge query fires on a timer in an
    # unrelated process and would make counts flap by one.
    unless meta.query =~ ~r/FROM "public"."oban_jobs".*GROUP BY/s do
      {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)
      send(pid, {:recorded_query, %{source: meta[:source], sql: meta.query, caller: caller(st)}})
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

  defp drain(acc) do
    receive do
      {:recorded_query, q} -> drain([q | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  def format(queries) do
    queries
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {q, i} ->
      "#{i}. [#{q.source || "-"}] #{q.sql |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)}\n     <- #{q.caller}"
    end)
  end
end
