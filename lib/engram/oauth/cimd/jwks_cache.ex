defmodule Engram.OAuth.Cimd.JwksCache do
  @moduledoc """
  Node-local cache of the signing keys a CIMD client publishes at its `jwks_uri`.

  ## Why this has to exist

  Without it, every token request refetches. The fetch sits behind a per-host
  bucket, so the bucket stops being a backstop and becomes the **capacity
  ceiling**: every user of a vendor shares one budget, and the request that
  exceeds it gets a 401 that RFC 6749 §5.2 makes terminal — the connector stops
  and the user sees a permanently dead integration. Refresh grants are
  unattended and cluster in time, so they saturate it with no user action at
  all.

  It is also what keeps the promise `Engram.OAuth.get_client/1` makes: network
  I/O belongs on the interactive authorize path, never on token exchange. The
  `jwks_uri` was copied onto the client row precisely so the token path would
  not have to go and look it up.

  ## Shape

  Keyed by `jwks_uri`, valued with the raw `keys` list. TTL-bounded, and
  additionally refreshable on demand: a `kid` we have never seen is the signal
  that a vendor rotated, and waiting out a TTL to notice would break every
  assertion in between. `refresh/1` has its own rate-limit bucket so a caller
  presenting unknown kids cannot turn that self-heal into an outbound hammer.

  Public keys only — published to the world by definition — so unlike
  `StemCache` this needs neither `:protected` nor `:sensitive`.

  Node-local and TTL-only: no cross-node eviction. A stale key set is
  self-correcting (the vendor's old key still verifies its own assertions) and
  the worst case is one refetch per node.
  """

  use Engram.Cache.NodeLocalEts,
    table: :engram_cimd_jwks_cache,
    ttl: :timer.hours(1)

  alias Engram.Logger.Metadata
  alias Engram.OAuth.Cimd.Fetcher
  alias EngramWeb.RateLimiter

  @window_ms 60_000

  # Only reached on a cache miss or an explicit rotation refresh, so this is a
  # backstop against a pathological vendor or a kid-miss storm — not the
  # steady-state path. Split buckets for the same reason `Engram.OAuth.Cimd`
  # splits discovery from refresh: a miss storm must not starve the rotation
  # self-heal for clients that are already connected.
  @miss_limit 30
  @refresh_limit 10

  @type reason :: :jwks_unavailable | :jwks_rate_limited

  @doc """
  Returns the published keys for `jwks_uri`, fetching on a cache miss.
  """
  @spec keys(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def keys(jwks_uri) when is_binary(jwks_uri) do
    case cache_lookup(jwks_uri) do
      {:ok, keys} -> {:ok, keys}
      :stale -> fetch_and_store(jwks_uri, "cimd:jwks:miss:", @miss_limit)
    end
  end

  @doc """
  Refetches `jwks_uri`, bypassing the cache.

  For the one case a TTL cannot answer: an assertion carrying a `kid` we have
  never seen, which means the vendor rotated. Bounded by its own bucket.
  """
  @spec refresh(String.t()) :: {:ok, [map()]} | {:error, reason()}
  def refresh(jwks_uri) when is_binary(jwks_uri) do
    fetch_and_store(jwks_uri, "cimd:jwks:refresh:", @refresh_limit)
  end

  defp fetch_and_store(jwks_uri, bucket_prefix, limit) do
    with :ok <- rate_limit(jwks_uri, bucket_prefix, limit),
         {:ok, keys} <- fetch(jwks_uri) do
      cache_put(jwks_uri, keys)
      {:ok, keys}
    end
  end

  # Reuses the CIMD document seam: identical SSRF guard, body cap, redirect
  # refusal and JSON content-type check. A second transport here would be a
  # second set of those decisions, free to drift from the tested one.
  defp fetch(jwks_uri) do
    case Fetcher.impl().fetch(jwks_uri) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok, keys}

      other ->
        # The vendor's endpoint answered with something unusable, or not at
        # all. Logged with the host because the whole point of this series is
        # that a vendor failing must be attributable to THAT vendor.
        Logger.warning(
          "mcp_jwks_unusable",
          Metadata.with_category(:warning, :lifecycle,
            cimd_host: host_of(jwks_uri),
            reason: Metadata.safe_reason(unusable_reason(other))
          )
        )

        {:error, :jwks_unavailable}
    end
  end

  defp unusable_reason({:error, reason}), do: reason
  defp unusable_reason({:ok, _no_keys_list}), do: :no_keys_array
  defp unusable_reason(_other), do: :unexpected_response

  # NOT laundered into :jwks_unavailable. A throttle is OUR side of the wire and
  # clears on its own; reporting it as the vendor's fault sends the operator to
  # check OpenAI's status page while the real cause is our own bucket, and hands
  # the client a terminal 401 for a condition that would have succeeded a second
  # later. Same split `Engram.OAuth.cimd_error/1` already makes.
  defp rate_limit(jwks_uri, bucket_prefix, limit) do
    case RateLimiter.hit(bucket_prefix <> host_of(jwks_uri), @window_ms, limit, :cimd_fetch) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :jwks_rate_limited}
    end
  end

  defp host_of(jwks_uri), do: URI.parse(jwks_uri).host || "unknown"
end
