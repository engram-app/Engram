defmodule Engram.ObanInsertCount do
  @moduledoc """
  Test helper for bounded fan-out (#2169): how many `INSERT INTO oban_jobs`
  statements a function issues from the calling process. Each statement is one
  pool checkout, so a bulk `insert_all` counts 1 where N single inserts count N.
  """

  @doc "Runs `fun`; returns `{result, insert_statement_count}`."
  @spec count((-> result)) :: {result, non_neg_integer()} when result: term()
  def count(fun) when is_function(fun, 0) do
    test = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _, _, %{query: q}, _ ->
        # The handler is global: count only the caller's own queries.
        if self() == test and q =~ ~r/^INSERT INTO .*"oban_jobs"/, do: send(test, {ref, :insert})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :insert} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
