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
  drain the refresh bucket a genuine rotation needs. Inside the cooldown, or
  when the refetch fails, the answer is a retryable 503: the held keys cannot
  vouch for a kid they do not contain.

  ## Waiters

  Concurrent requests for one URI share one fetch. A waiter that holds usable
  keys serves them at once; one with none waits until the flight's recorded
  deadline (DNS + fetch budget + store).
  """

  import Ecto.Query

  alias Engram.Analytics.McpClient
  alias Engram.Cache
  alias Engram.Http.SsrfGuard
  alias Engram.OAuth
  alias Engram.OAuth.Cimd
  alias Engram.OAuth.Cimd.Fetcher
  alias Engram.OAuth.Cimd.HttpFetcher
  alias Engram.OAuth.Client
  alias Engram.Repo
  alias EngramWeb.RateLimiter

  @flights __MODULE__.Flights
  @source_key :engram_jwks_source

  @fresh_ms 15 * 60_000
  @stale_ms 7 * 86_400_000
  @kid_miss_cooldown_ms 30_000

  # A flight's deadline: DNS + the fetch budget + the store. Recorded in the
  # registry by the flight owner so waiters wait exactly as long as it can run.
  @flight_store_ms 500
  @flight_poll_ms 20

  @window_ms 60_000
  @miss_limit 30
  @refresh_limit 10
  # The background sweep, per vendor host per minute: bounds what one sweep
  # can send to one vendor however many of its clients are registered.
  @sweep_limit 20

  @type reason :: :jwks_unavailable | :jwks_invalid | :jwks_rate_limited

  @doc "Returns the usable keys for `jwks_uri`, fetching only when none are fresh."
  @spec keys(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def keys(jwks_uri) when is_binary(jwks_uri) do
    case lookup(jwks_uri) do
      {:fresh, keys, source} ->
        put_source(source)
        {:ok, keys}

      {:stale, keys, _source} ->
        fetch(jwks_uri, {"cimd:jwks:miss:", @miss_limit}, :token, keys)

      :none ->
        fetch(jwks_uri, {"cimd:jwks:miss:", @miss_limit}, :token, nil)
    end
  end

  @doc """
  Refetches `jwks_uri` after an unknown `kid`.

  The keys we hold cannot answer this (the kid is not in them), so they are
  never the fallback: a refetch that is skipped (inside the per-URI cooldown),
  throttled or failed answers a transient `:jwks_unavailable` /
  `:jwks_rate_limited` (503, retry), never the held set, which would turn into
  a terminal 401 for what may be a genuine rotation (review #3 of #1974).
  """
  @spec refresh(String.t()) :: {:ok, [map()]} | {:error, :jwks_unavailable | :jwks_rate_limited}
  def refresh(jwks_uri) when is_binary(jwks_uri) do
    if cooling_down?(jwks_uri) do
      {:error, :jwks_unavailable}
    else
      Cache.put(:jwks, {:kid_miss, jwks_uri}, now_ms())
      fetch(jwks_uri, {"cimd:jwks:refresh:", @refresh_limit}, :kid_miss, nil)
    end
  end

  @doc """
  Background refetch for `Engram.Workers.CimdRefresh`. Returns `{:error, _}`
  whenever the vendor did not answer, so the sweep can count it; but while
  usable keys are held that is a warning (`mcp_jwks_refresh_failed`,
  `result=stale`), not a page: nothing a client sees is broken yet.
  """
  @spec refresh_background(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def refresh_background(jwks_uri) when is_binary(jwks_uri),
    do: fetch(jwks_uri, {"cimd:jwks:sweep:", @sweep_limit}, :background, usable_keys(jwks_uri))

  @doc """
  Where the keys behind the last `keys/1` / `refresh/1` in this process came
  from (`:cache | :persisted | :fetched | :stale`), and forgets it. For the
  `mcp_oauth_token_issued` analytics prop; nil when no assertion was checked.
  """
  @spec take_source() :: :cache | :persisted | :fetched | :stale | nil
  def take_source, do: Process.delete(@source_key)

  defp put_source(source), do: Process.put(@source_key, source)

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
      {_, keys, _source} -> keys
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
            Map.put(row, :source, :persisted)
          else
            node
          end
      end
    end
  end

  defp node_entry(jwks_uri) do
    case Cache.get(:jwks, jwks_uri) do
      {:ok, %{keys: _, fetched_at: _} = entry} -> Map.put(entry, :source, :cache)
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

  defp classify(%{keys: keys, fetched_at: at, source: source}) do
    age = wall_ms() - at

    cond do
      age < @fresh_ms -> {:fresh, keys, source}
      age < @stale_ms -> {:stale, keys, source}
      true -> :none
    end
  end

  # ── Fetch ───────────────────────────────────────────────────────────

  # `mode` is who asked: `:token` (an assertion is waiting; `held` is the
  # stale set to serve if the fetch fails), `:kid_miss` (rotation refetch; no
  # fallback) or `:background` (the sweep; `held` only decides warn vs page).
  defp fetch(jwks_uri, bucket, mode, held) do
    waiter_fallback = if mode == :token, do: held

    single_flight(jwks_uri, waiter_fallback, fn ->
      fetch_and_store(jwks_uri, bucket, mode, held)
    end)
  end

  defp fetch_and_store(jwks_uri, bucket, mode, held) do
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
        put_source(:fetched)
        {:ok, keys}

      {:error, cause} ->
        fetch_failed(mode, jwks_uri, held, cause, duration)
    end
  end

  # Stale keys served to a waiting assertion: a warning, the vendor is down.
  defp fetch_failed(:token, jwks_uri, held, cause, duration) when is_list(held) do
    log_unusable("mcp_jwks_stale_served", jwks_uri, cause)
    report(jwks_uri, :stale, cause, duration)
    put_source(:stale)
    {:ok, held}
  end

  # The sweep failed but usable keys remain: a warning, not a page.
  defp fetch_failed(:background, jwks_uri, held, cause, duration) when is_list(held) do
    log_unusable("mcp_jwks_refresh_failed", jwks_uri, cause)
    report(jwks_uri, :stale, cause, duration)
    {:error, classify_error(cause)}
  end

  # A rotation refetch that failed: the kid cannot be checked, so retryable.
  defp fetch_failed(:kid_miss, jwks_uri, _held, cause, duration) do
    log_unusable("mcp_jwks_refresh_failed", jwks_uri, cause)
    report(jwks_uri, :error, cause, duration)
    {:error, transient_error(cause)}
  end

  # Nothing usable at all: the page.
  defp fetch_failed(_mode, jwks_uri, _held, cause, duration) do
    log_unusable("mcp_jwks_unusable", jwks_uri, cause)
    report(jwks_uri, :error, cause, duration)
    {:error, classify_error(cause)}
  end

  defp report(jwks_uri, result, cause, duration) do
    Cimd.emit_fetch(:jwks, result, cause, duration)
    track_fetch_failed(jwks_uri, result, cause)
  end

  defp transient_error(:jwks_rate_limited), do: :jwks_rate_limited
  defp transient_error(_cause), do: :jwks_unavailable

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

  # Server-side and about a vendor, not a person: anonymous (#1974). Only the
  # bounded vendor family, never the host: a CIMD jwks_uri host is whatever
  # domain an unauthenticated caller registered (review #11).
  defp track_fetch_failed(jwks_uri, result, cause) do
    Engram.Analytics.track_anonymous("mcp_oauth_jwks_fetch_failed", %{
      client: McpClient.family(Cimd.host_of(jwks_uri)),
      reason: Atom.to_string(Cimd.fetch_reason_label(cause)),
      phase: phase_of(cause),
      result: Atom.to_string(result)
    })
  end

  defp phase_of({:transport_error, phase, _}) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_of(_cause), do: nil

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
  defp rate_limit(jwks_uri, {prefix, limit}) do
    case RateLimiter.hit(prefix <> Cimd.host_of(jwks_uri), @window_ms, limit, :cimd_fetch) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :jwks_rate_limited}
    end
  end

  # ── Single-flight ───────────────────────────────────────────────────

  # ponytail: waiters poll the registry rather than subscribing; a flight
  # lasts at most its recorded deadline (~4.5 s), so a 20 ms poll costs nothing.
  #
  # A waiter that already holds usable keys (`fallback`) does not wait at all:
  # it serves them, exactly as it would if the flight failed (review #9).
  defp single_flight(jwks_uri, fallback, fun) do
    case Registry.register(@flights, jwks_uri, flight_deadline()) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(@flights, jwks_uri)
        end

      {:error, {:already_registered, _owner}} when is_list(fallback) ->
        put_source(:stale)
        {:ok, fallback}

      {:error, {:already_registered, _owner}} ->
        await_flight(jwks_uri)
    end
  end

  defp flight_deadline do
    now_ms() + SsrfGuard.dns_timeout_ms() + HttpFetcher.budget_ms() + @flight_store_ms
  end

  # Waits until the flight ends or reaches the deadline its owner recorded.
  # Keys a finished flight left behind are reported as `:fetched` when fresh
  # (the flight fetched them) and `:stale` otherwise (#1974 review #13).
  defp await_flight(jwks_uri) do
    case Registry.lookup(@flights, jwks_uri) do
      [] ->
        case classify(newest_entry(jwks_uri)) do
          {:fresh, keys, _source} ->
            put_source(:fetched)
            {:ok, keys}

          {:stale, keys, _source} ->
            put_source(:stale)
            {:ok, keys}

          :none ->
            {:error, :jwks_unavailable}
        end

      [{_owner, deadline}] ->
        if now_ms() > deadline do
          {:error, :jwks_unavailable}
        else
          Process.sleep(@flight_poll_ms)
          await_flight(jwks_uri)
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp wall_ms, do: System.system_time(:millisecond)
end
