defmodule Engram.Billing.PlanCache do
  @moduledoc """
  Caches each plan's `limits` map in `:persistent_term`, keyed by plan id.

  Plan rows are seeded and effectively static at runtime (no code path writes
  them), so the per-request `plan_lookup` query in `Engram.Billing` is pure
  repetition for API-key traffic. `:persistent_term` is the right store for
  rarely-changing global data: reads are lock-free with zero copying, and the
  expensive global rebuild on write only happens on a cold miss (a handful of
  plans over the node's lifetime).

  If plans are ever edited at runtime (e.g. an admin/catalog task), call
  `invalidate/1` for the changed plan id (or `invalidate_all/0`) so the next
  read reloads from the DB.
  """

  import Ecto.Query
  alias Engram.Billing.Plan
  alias Engram.Repo

  @doc """
  Returns the cached limits map for `plan_id`, loading and caching it on a
  miss. An unknown plan id resolves to an empty map (no limits).
  """
  @spec limits(plan_id :: integer()) :: map()
  def limits(plan_id) do
    case :persistent_term.get(key(plan_id), :__miss__) do
      :__miss__ ->
        loaded = load(plan_id)
        :persistent_term.put(key(plan_id), loaded)
        loaded

      cached ->
        cached
    end
  end

  @spec invalidate(plan_id :: integer()) :: :ok
  def invalidate(plan_id) do
    _ = :persistent_term.erase(key(plan_id))
    :ok
  end

  @doc """
  Drops every cached plan. Call after a bulk plan-limit change (e.g. re-running
  seeds) so the next lookup reloads from the DB. A fresh deploy starts with a
  cold cache, so this is only needed when limits change without a restart.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    for {{__MODULE__, _plan_id} = k, _v} <- :persistent_term.get() do
      :persistent_term.erase(k)
    end

    :ok
  end

  defp load(plan_id) do
    case Repo.one(
           from(p in Plan, where: p.id == ^plan_id, select: p.limits),
           skip_tenant_check: true
         ) do
      limits when is_map(limits) -> limits
      # Unknown plan id, or a malformed (non-map) limits column. Resolve to an
      # empty map so `plan_lookup` falls through to tier defaults rather than
      # raising BadMapError on the request path.
      _ -> %{}
    end
  end

  defp key(plan_id), do: {__MODULE__, plan_id}
end
