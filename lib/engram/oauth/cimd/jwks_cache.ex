defmodule Engram.OAuth.Cimd.JwksCache do
  @moduledoc """
  The signing keys a CIMD client publishes at its `jwks_uri`: node-local in the
  `:jwks` cache, persisted on every `oauth_clients` row naming that URI.

  ## Why this has to exist

  Without it, every token request refetches. The fetch sits behind a per-host
  bucket, so the bucket stops being a backstop and becomes the **capacity
  ceiling**, and the request that exceeds it gets a 401 that RFC 6749 §5.2
  makes terminal. It is also what keeps the promise `Engram.OAuth.get_client/1`
  makes: network I/O belongs on the interactive authorize path, never on token
  exchange.

  ## Never fail while we hold a good key (#1974)

  On 2026-10-13 a ChatGPT token request 503'd because the JWKS fetch timed out
  on a key we had verified many times before. So:

    * an entry is **fresh** for #{div(15 * 60_000, 60_000)} min after its fetch,
      then **stale but usable** for up to 7 days while refetches fail. Public
      keys only verify what the vendor already signed, so serving them late
      is safe (Hydra and Keycloak do the same);
    * every good fetch is **persisted** (`jwks_cached`, `jwks_fetched_at`), so
      a new node or a deploy starts warm instead of fetching on the token path;
    * `Engram.Workers.CimdRefresh` (`kind: "jwks"`) refetches every known
      `jwks_uri` every 5 min, so the token path normally finds a fresh row;
    * concurrent misses on one node make **one** fetch (single-flight);
    * a failure is classified: transient (transport, 5xx, 429) →
      `:jwks_unavailable` (503, retryable); anything else → `:jwks_invalid`
      (401). Only when there is no usable key at all.

  Freshness ignores the vendor's `Cache-Control: max-age`: the background
  refresh runs every 5 min, well inside the spec's 5 min to 1 h clamp, so
  honoring it would change nothing a client can observe.

  ## Rotation

  A `kid` we have never seen means the vendor rotated: `refresh/1` refetches,
  at most once per #{div(30_000, 1000)} s per URI, so random-`kid` probes cannot
  drain the refresh bucket a genuine rotation needs.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.OAuth
  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Cimd.Fetcher
  alias Engram.OAuth.Client
  alias Engram.Repo
  alias EngramWeb.RateLimiter

  @flights __MODULE__.Flights

  @fresh_ms 15 * 60_000
  @stale_ms 7 * 86_400_000
  @kid_miss_cooldown_ms 30_000

  # A waiter gives up a little after the 3 s fetch budget.
  @flight_wait_ms 3_500
  @flight_poll_ms 20

  @window_ms 60_000
  @miss_limit 30
  @refresh_limit 10

  @type reason :: :jwks_unavailable | :jwks_invalid | :jwks_rate_limited

  @doc "Returns the usable keys for `jwks_uri`, fetching only when none are fresh."
  @spec keys(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def keys(jwks_uri) when is_binary(jwks_uri) do
    case lookup(jwks_uri) do
      {:fresh, keys} -> {:ok, keys}
      {:stale, keys} -> fetch(jwks_uri, {"cimd:jwks:miss:", @miss_limit}, keys)
      :none -> fetch(jwks_uri, {"cimd:jwks:miss:", @miss_limit}, nil)
    end
  end

  @doc """
  Refetches `jwks_uri` after an unknown `kid`. Inside the per-URI cooldown it
  returns the keys we already hold without fetching, so the caller reports the
  `kid` as unknown.
  """
  @spec refresh(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def refresh(jwks_uri) when is_binary(jwks_uri) do
    held = usable_keys(jwks_uri)

    if cooling_down?(jwks_uri) and held != nil do
      {:ok, held}
    else
      Cache.put(:jwks, {:kid_miss, jwks_uri}, now_ms())
      fetch(jwks_uri, {"cimd:jwks:refresh:", @refresh_limit}, held)
    end
  end

  @doc """
  Background refetch for `Engram.Workers.CimdRefresh`. No rate-limit bucket
  (one job every 5 min is the bound) and no stale fallback: the worker wants
  to know whether the vendor answered.
  """
  @spec refresh_background(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def refresh_background(jwks_uri) when is_binary(jwks_uri),
    do: fetch(jwks_uri, nil, nil)

  @doc false
  # Test hook standing in for 30 s passing.
  @spec expire_kid_miss_cooldown(String.t()) :: :ok
  def expire_kid_miss_cooldown(jwks_uri), do: Cache.evict_local(:jwks, {:kid_miss, jwks_uri})

  defp cooling_down?(jwks_uri) do
    case Cache.get(:jwks, {:kid_miss, jwks_uri}) do
      {:ok, at} -> now_ms() - at < @kid_miss_cooldown_ms
      :miss -> false
    end
  end

  # ── Lookup: node cache, then the persisted row ─────────────────────

  defp lookup(jwks_uri), do: classify(newest_entry(jwks_uri))

  defp usable_keys(jwks_uri) do
    case classify(newest_entry(jwks_uri)) do
      {_, keys} -> keys
      :none -> nil
    end
  end

  # The node entry unless it is fresh-enough to skip the database; otherwise
  # whichever of node and row was fetched last. The row is what the background
  # refresh (running on another node) keeps current.
  defp newest_entry(jwks_uri) do
    node = node_entry(jwks_uri)

    if fresh?(node) do
      node
    else
      case persisted_entry(jwks_uri) do
        nil ->
          node

        row ->
          if node == nil or row.fetched_at > node.fetched_at do
            Cache.put(:jwks, jwks_uri, row)
            row
          else
            node
          end
      end
    end
  end

  defp node_entry(jwks_uri) do
    case Cache.get(:jwks, jwks_uri) do
      {:ok, %{keys: _, fetched_at: _} = entry} -> entry
      _ -> nil
    end
  end

  # `skip_tenant_check`: an OAuth client is not tenant-scoped.
  defp persisted_entry(jwks_uri) do
    Repo.one(
      from(c in Client,
        where: c.jwks_uri == ^jwks_uri and not is_nil(c.jwks_fetched_at),
        order_by: [desc: c.jwks_fetched_at],
        limit: 1,
        select: {c.jwks_cached, c.jwks_fetched_at}
      ),
      skip_tenant_check: true
    )
    |> case do
      {%{"keys" => keys}, %DateTime{} = at} when is_list(keys) ->
        %{keys: keys, fetched_at: DateTime.to_unix(at, :millisecond)}

      _ ->
        nil
    end
  end

  defp fresh?(nil), do: false
  defp fresh?(%{fetched_at: at}), do: wall_ms() - at < @fresh_ms

  defp classify(nil), do: :none

  defp classify(%{keys: keys, fetched_at: at}) do
    age = wall_ms() - at

    cond do
      age < @fresh_ms -> {:fresh, keys}
      age < @stale_ms -> {:stale, keys}
      true -> :none
    end
  end

  # ── Fetch ───────────────────────────────────────────────────────────

  # `held` is the stale key set to fall back on, or nil.
  defp fetch(jwks_uri, bucket, held) do
    single_flight(jwks_uri, fn -> fetch_and_store(jwks_uri, bucket, held) end)
  end

  defp fetch_and_store(jwks_uri, bucket, held) do
    started = now_ms()

    result =
      with :ok <- rate_limit(jwks_uri, bucket) do
        fetch_keys(jwks_uri)
      end

    duration = now_ms() - started

    case result do
      {:ok, keys} ->
        store(jwks_uri, keys)
        Cimd.emit_fetch(:jwks, :ok, nil, duration)
        {:ok, keys}

      {:error, cause} when is_list(held) ->
        log_unusable("mcp_jwks_stale_served", jwks_uri, cause)
        Cimd.emit_fetch(:jwks, :stale, cause, duration)
        {:ok, held}

      {:error, cause} ->
        log_unusable("mcp_jwks_unusable", jwks_uri, cause)
        Cimd.emit_fetch(:jwks, :error, cause, duration)
        {:error, classify_error(cause)}
    end
  end

  # Reuses the CIMD document seam: identical SSRF guard, body cap, redirect
  # refusal and JSON content-type check.
  defp fetch_keys(jwks_uri) do
    case Fetcher.impl().fetch(jwks_uri) do
      {:ok, %{"keys" => keys}} when is_list(keys) -> {:ok, keys}
      {:ok, _no_keys_list} -> {:error, :no_keys_array}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store(jwks_uri, keys) do
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(c in Client, where: c.jwks_uri == ^jwks_uri),
      [set: [jwks_cached: %{"keys" => keys}, jwks_fetched_at: now]],
      skip_tenant_check: true
    )

    Cache.put(:jwks, jwks_uri, %{keys: keys, fetched_at: DateTime.to_unix(now, :millisecond)})
  end

  # Logged with the host because a vendor failing must be attributable to
  # THAT vendor.
  defp log_unusable(event, jwks_uri, cause), do: OAuth.log_refusal(event, jwks_uri, cause)

  # Ours and transient → retryable 503. The vendor answering with something
  # that will not become a JWKS on retry → terminal 401.
  defp classify_error(:jwks_rate_limited), do: :jwks_rate_limited

  defp classify_error(cause),
    do: if(Cimd.transient_fetch_error?(cause), do: :jwks_unavailable, else: :jwks_invalid)

  # NOT laundered into :jwks_unavailable. A throttle is OUR side of the wire
  # and clears on its own (same split as `Engram.OAuth.cimd_error/1`).
  defp rate_limit(_jwks_uri, nil), do: :ok

  defp rate_limit(jwks_uri, {prefix, limit}) do
    case RateLimiter.hit(prefix <> Cimd.host_of(jwks_uri), @window_ms, limit, :cimd_fetch) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :jwks_rate_limited}
    end
  end

  # ── Single-flight ───────────────────────────────────────────────────

  # ponytail: waiters poll the registry rather than subscribing; a flight
  # lasts at most the 3 s fetch budget, so a 20 ms poll costs nothing.
  defp single_flight(jwks_uri, fun) do
    case Registry.register(@flights, jwks_uri, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(@flights, jwks_uri)
        end

      {:error, {:already_registered, _owner}} ->
        await_flight(jwks_uri, now_ms() + @flight_wait_ms)
    end
  end

  defp await_flight(jwks_uri, deadline) do
    cond do
      Registry.lookup(@flights, jwks_uri) == [] ->
        case usable_keys(jwks_uri) do
          nil -> {:error, :jwks_unavailable}
          keys -> {:ok, keys}
        end

      now_ms() > deadline ->
        {:error, :jwks_unavailable}

      true ->
        Process.sleep(@flight_poll_ms)
        await_flight(jwks_uri, deadline)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp wall_ms, do: System.system_time(:millisecond)
end
