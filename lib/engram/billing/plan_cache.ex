defmodule Engram.Billing.PlanCache do
  @moduledoc """
  Caches each plan's `limits` map (`:plan` in `Engram.Cache.Registry`, no TTL), keyed by plan id.

  Plan rows are seeded and effectively static at runtime (no code path writes
  them), so the per-request `plan_lookup` query in `Engram.Billing` is pure
  repetition for API-key traffic. Entries never expire; only `invalidate/1` and
  `invalidate_all/0` drop them (cluster-wide).

  If plans are ever edited at runtime (e.g. an admin/catalog task), call
  `invalidate/1` for the changed plan id (or `invalidate_all/0`) so the next
  read reloads from the DB.
  """

  import Ecto.Query
  alias Engram.Billing.Plan
  alias Engram.Cache
  alias Engram.Repo

  @doc """
  Returns the cached limits map for `plan_id`, loading and caching it on a
  miss. An unknown plan id resolves to an empty map (no limits).
  """
  @spec limits(plan_id :: Ecto.UUID.t()) :: map()
  def limits(plan_id), do: Cache.fetch(:plan, plan_id, fn -> load(plan_id) end)

  @spec invalidate(plan_id :: Ecto.UUID.t()) :: :ok
  def invalidate(plan_id), do: Cache.evict(:plan, plan_id)

  @doc """
  Drops every cached plan. Call after a bulk plan-limit change (e.g. re-running
  seeds) so the next lookup reloads from the DB. A fresh deploy starts with a
  cold cache, so this is only needed when limits change without a restart.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all, do: Cache.evict_all(:plan)

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
end
