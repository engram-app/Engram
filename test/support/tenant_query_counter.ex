defmodule Engram.TenantQueryCounter do
  @moduledoc """
  Counts `[:engram, :repo, :query]` telemetry events matching a predicate,
  observed while `fun` runs. Used to assert on `Repo.with_tenant/2`'s wire
  shape without a real Postgres round trip per assertion.

  Used as a regression guard against with_tenant round-trip counts creeping
  back up (#1211): `Engram.RepoTenantRoundtripsTest`,
  `EngramWeb.SyncControllerTest`, `EngramWeb.VaultTreeControllerTest`. One
  canonical implementation — three separate copies is how a probe drifts out
  of sync with itself and silently stops asserting anything real.
  """

  @doc "Runs `fun`, returns the list of query texts for which `matcher.(query)` is truthy."
  def count_matching_queries(fun, matcher) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _e, _m, %{query: q}, _c ->
        if self() == test_pid and matcher.(q) do
          send(test_pid, {:matched_query, q})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect()
  end

  @doc """
  Counts `with_tenant/2` invocations that actually open a transaction, via
  the combined `SELECT set_config('app.current_tenant', ...)` statement each
  one emits (`run_with_tenant/2` in `lib/engram/repo.ex`) — a re-entrant
  nested call for the same tenant emits none. One entry per block, not two
  (see `count_wire_statements/1` for enter+exit together).
  """
  def count_tenant_enters(fun) do
    count_matching_queries(fun, &(&1 =~ "app.current_tenant"))
  end

  @doc """
  Counts the full `with_tenant/2` utility-statement wire shape: the combined
  `set_config` (enter) and the `RESET`/`set_config('role', 'none', ...)`
  (exit) — 2 statements per block, not 1. For asserting the wire shape
  itself (`Engram.RepoTenantRoundtripsTest`), not just block count.
  """
  def count_wire_statements(fun) do
    count_matching_queries(fun, &(&1 =~ "set_config" or &1 =~ ~r/^(SET|RESET)/))
  end

  defp collect(acc \\ []) do
    receive do
      {:matched_query, q} -> collect([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
