defmodule Engram.Onboarding.GateCache do
  @moduledoc """
  Node-local cache (`:onboarding_gate` in `Engram.Cache.Registry`) of the RequireOnboarding PASS verdict, keyed by user id.

  Deriving the verdict costs ~3 DB round-trips per request (profile re-read +
  `has_vault?` inside its own RLS transaction) for an answer that is true for
  essentially every post-onboarding request. Only PASS is cached — failing
  users always hit the authoritative slow path, so a stale entry can never
  withhold access, only briefly extend it.

  Staleness is bounded two ways:

    * every pass→fail transition has an eviction write-site — vault deletion
      (`Engram.Vaults.delete_vault/2`), subscription mutation (every
      `Engram.Billing.upsert_from_paddle_event/1` clause via
      `broadcast_subscription_activated/2`), profile edits
      (`Engram.Onboarding.set_profile/2`), and a terms-floor bump
      (`Engram.Legal.VersionCache.invalidate_all/0`, which calls `evict_all/0`);
    * a #{div(60_000, 1000)}s TTL backstops any write-site this list misses.

  Cross-node: evictions ride `Engram.Cluster.CacheSync` exactly like
  `Engram.Crypto.DekCache` — the mutating node clears its own table
  synchronously, peers clear on the broadcast.
  """

  alias Engram.Cache

  @ttl_ms 60_000

  @spec passed?(Ecto.UUID.t()) :: boolean()
  def passed?(user_id) do
    case Cache.get(:onboarding_gate, user_id) do
      {:ok, expires_at} -> System.monotonic_time(:millisecond) < expires_at
      :miss -> false
    end
  end

  @doc """
  `:ok` on a cached PASS; otherwise runs `derive` (the authoritative slow
  path). A `:pass` result is returned as `:ok` and stored through
  `Engram.Cache.fetch/3`'s pending-marker guard, so an eviction that lands
  while `derive` runs (a cancellation committing after its reads) wins and the
  PASS is not stored. Any other result is returned as is, uncached.
  """
  @spec verdict(Ecto.UUID.t(), (-> :pass | result)) :: :ok | result when result: term()
  def verdict(user_id, derive) do
    if passed?(user_id) do
      :ok
    else
      # A PASS past its own deadline (mark_passed/2 with a short ttl) is
      # still a row, which fetch/3 would serve.
      if match?({:ok, _}, Cache.get(:onboarding_gate, user_id)),
        do: :ok = Cache.evict_local(:onboarding_gate, user_id)

      loader = fn ->
        case derive.() do
          :pass -> System.monotonic_time(:millisecond) + @ttl_ms
          other -> Cache.no_store(other)
        end
      end

      case Cache.fetch(:onboarding_gate, user_id, loader) do
        deadline when is_integer(deadline) -> :ok
        other -> other
      end
    end
  end

  # Seeds a PASS with no race guard (tests). Production stores through
  # verdict/2. The stored value is the verdict's own deadline, so a
  # caller-chosen ttl_ms (shorter than the registry TTL) is honoured.
  @spec mark_passed(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def mark_passed(user_id, ttl_ms \\ @ttl_ms) do
    Cache.put(:onboarding_gate, user_id, System.monotonic_time(:millisecond) + ttl_ms)
  end

  @doc """
  Clears the verdict locally and broadcasts the eviction to peer nodes.
  Idempotent; receiving our own broadcast is a harmless double-delete.
  """
  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(user_id), do: Cache.evict(:onboarding_gate, user_id)

  # A terms (re)seed or publish can raise the required floor, flipping any
  # passed user back to failing; `Engram.Legal.VersionCache.invalidate_all/0`
  # calls this to drop every verdict and re-derive.
  @spec evict_all() :: :ok
  def evict_all, do: Cache.evict_all(:onboarding_gate)
end
