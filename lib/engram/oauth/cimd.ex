defmodule Engram.OAuth.Cimd do
  @moduledoc """
  Client ID Metadata Documents: resolving a URL-shaped `client_id` to a client.

  ## What it is

  IETF `draft-ietf-oauth-client-id-metadata-document`, adopted by MCP
  `2025-11-25`. Instead of registering (RFC 7591 DCR), a client's `client_id` IS
  an HTTPS URL its vendor owns, and the authorization server fetches that URL to
  obtain the client's metadata.

  ## Why we want it

  Verification here is granted by exactly one thing: proof that the party we are
  talking to controls a host the vendor owns. A vendor-owned HTTPS *redirect*
  host proves that, because the auth code is delivered to the vendor and not to
  a forger. Loopback clients (Claude Code, Cline, Cursor, OpenCode, Windsurf)
  have no such host, so they are unverifiable **by construction** — the
  `client_name` fallback in `Engram.Connections.LogoAllowlist` attributes them,
  but attribution is not proof.

  CIMD supplies the missing proof for exactly that class: nobody but Anthropic
  can serve a document at `claude.ai`, so the URL's host is un-spoofable for the
  same reason the redirect host is.

  It also gets us off a deprecated path. MCP `2025-11-25` demoted DCR from
  SHOULD to MAY, and the July 2026 spec update deprecates it.

  ## DCR is not going away

  This is additive. Seven of the nine connectors observed in prod do not use
  CIMD, and self-hosted clients (Open WebUI, LobeChat) never can — there is no
  vendor to publish a document. DCR stays as the floor. The two paths do not
  interact: a CIMD client sends a URL-shaped `client_id` and never touches
  `/oauth/register`.

  ## The document is not trusted, it is *bound*

  The whole security argument reduces to one check: the document's own
  `client_id` field MUST equal the URL it was served from. Without it a vendor
  could serve a document claiming any client_id, or an open redirect on a
  vendor's host could be used to serve someone else's metadata. Everything else
  the document says is then attributable to whoever controls that host, which is
  the point.

  ## Fetching a URL an attacker chose

  `/oauth/authorize` is unauthenticated, so this is an unauthenticated-request-
  triggered outbound fetch — an SSRF primitive and a traffic amplifier. Guards:

    * `Engram.Http.SsrfGuard` validates the URL and pins the connection to a
      verified public address (see that module for the DNS-rebinding argument).
    * Redirects are NOT followed. A redirect is a new URL that would bypass the
      guard that approved the first one. A vendor that redirects its metadata
      document simply does not work, which is the correct outcome.
    * The body is capped mid-stream, so a hostile vendor cannot stream gigabytes
      into our heap.
    * Two rate-limit buckets: per-host, and global. Per-host alone is useless
      against an attacker who varies the host, which is the amplification case.

  ## Caching

  The `oauth_clients` row IS the cache; `cimd_fetched_at` is its clock. The
  redirect allowlist is derived from the document and has to be durable anyway,
  so a second in-memory cache would only add a way for the two to disagree.

  A refresh that fails keeps serving the stale row. A vendor being briefly
  unreachable must not break sign-in for every user of that client, and a
  document we fetched yesterday is far better evidence than nothing.
  """

  import Ecto.Query

  alias Engram.Http.SsrfGuard
  alias Engram.Logger.Metadata
  alias Engram.OAuth.Cimd.Fetcher
  alias Engram.OAuth.Client
  alias Engram.Repo
  alias EngramWeb.RateLimiter

  require Logger

  @ttl_seconds 24 * 3600

  # Per minute. The global bucket is the one that matters: an attacker varying
  # the host walks straight past a per-host limit, and unmetered outbound fetches
  # aimed at third parties is what makes this an amplifier rather than just a
  # load risk for us.
  @per_host_limit 10
  @discover_limit 60
  @refresh_limit 10
  @window_ms 60_000

  @type reason ::
          :not_cimd
          | :rate_limited
          | :client_id_mismatch
          | :missing_redirect_uris
          | :confidential_not_supported
          | :body_too_large
          | :not_json
          | :invalid_json
          | :invalid_document
          | :fetch_failed
          | {:http_status, pos_integer()}
          | SsrfGuard.reason()

  @doc """
  True when `client_id` is shaped like a CIMD identifier rather than a DCR UUID.

  The `https://` prefix is the whole discriminator, and it is deliberately not
  "anything that fails to parse as a UUID": that would send every typo and probe
  down the fetch path.
  """
  @spec url_shaped?(term()) :: boolean()
  def url_shaped?(client_id) when is_binary(client_id),
    do: String.starts_with?(client_id, "https://")

  def url_shaped?(_), do: false

  @doc """
  Returns the client for a CIMD `client_id`, fetching or refreshing its document
  as needed. This is the only entry point that performs network I/O.

  `Engram.OAuth.get_client/1` stays a pure database lookup, so the token,
  refresh and revoke paths resolve an already-known CIMD client without ever
  reaching out.
  """
  @spec ensure_client(term()) :: {:ok, Client.t()} | {:error, reason()}
  def ensure_client(url) do
    if url_shaped?(url), do: ensure(url), else: {:error, :not_cimd}
  end

  @doc "Looks up a CIMD client by its URL. No network I/O."
  @spec get_by_url(term()) :: {:ok, Client.t()} | {:error, :not_found}
  def get_by_url(url) when is_binary(url) do
    case Repo.one(from(c in Client, where: c.cimd_url == ^url), skip_tenant_check: true) do
      nil -> {:error, :not_found}
      client -> {:ok, client}
    end
  end

  def get_by_url(_), do: {:error, :not_found}

  defp ensure(url) do
    case get_by_url(url) do
      {:ok, client} -> if fresh?(client), do: {:ok, client}, else: refresh(client, url)
      {:error, :not_found} -> fetch_and_store(url, nil)
    end
  end

  defp fresh?(%Client{cimd_fetched_at: nil}), do: false

  defp fresh?(%Client{cimd_fetched_at: fetched_at}),
    do: DateTime.diff(DateTime.utc_now(), fetched_at, :second) < @ttl_seconds

  # A stale row whose refresh fails keeps being served. Availability beats
  # freshness here: the alternative is that a vendor's five-minute outage locks
  # out every user of that client.
  defp refresh(client, url) do
    case fetch_and_store(url, client) do
      {:ok, refreshed} ->
        {:ok, refreshed}

      {:error, reason} ->
        log_unless_rate_limited("mcp_cimd_stale_retained", url, reason)
        {:ok, client}
    end
  end

  defp fetch_and_store(url, existing) do
    with :ok <- rate_limit(url, existing),
         {:ok, document} <- Fetcher.impl().fetch(url),
         :ok <- validate_document(document, url),
         {:ok, client} <- store(url, document, existing) do
      {:ok, client}
    else
      {:error, reason} ->
        log_unless_rate_limited("mcp_cimd_rejected", url, reason)
        {:error, reason}
    end
  end

  # A rate-limit denial is deliberately NOT logged, on either path. The fetch is
  # bounded but the log line would not be: /oauth/authorize is unauthenticated, so
  # a caller varying the URL — or simply replaying one known-stale client — earns
  # one Loki line per attempt while the limiter cheaply refuses each one.
  # Unbounded log volume behind a bounded side effect.
  #
  # The limiter already emits `[:engram, :rate_limiter, :hit]` with
  # `purpose: :cimd_fetch, result: :deny`, so the volume is visible as a metric,
  # which is the right shape for it. Logs stay for anomalies.
  defp log_unless_rate_limited(_event, _url, :rate_limited), do: :ok
  defp log_unless_rate_limited(event, url, reason), do: log(event, url, reason)

  # Two budgets, deliberately separate, because they face different callers.
  #
  # DISCOVERY (`existing == nil`) is the attacker-reachable path: any
  # unauthenticated /oauth/authorize may name a URL we have never seen. Bounded
  # per-host AND globally — a per-host limit alone does nothing against a caller
  # varying the host, which is exactly the amplification case.
  #
  # REFRESH (`existing != nil`) requires a row that already passed discovery, so
  # it cannot be reached without first getting a document accepted. It gets its
  # OWN bucket so that saturating the discovery budget cannot starve refreshes for
  # vendors real users are already connected to. Sharing one global bucket would
  # turn this anti-amplification control into a denial-of-service vector against
  # the clients we actually serve: an attacker cycling hosts would consume the
  # budget and every legitimate refresh would then fall back to a stale document
  # until its TTL work could get through.
  #
  # Refresh is still per-host capped: a vendor that is down leaves its row
  # permanently stale, so every authorize for that client retries the fetch.
  defp rate_limit(url, nil) do
    with {:allow, _} <-
           RateLimiter.hit("cimd:discover", @window_ms, @discover_limit, :cimd_fetch),
         {:allow, _} <-
           RateLimiter.hit("cimd:host:" <> host_of(url), @window_ms, @per_host_limit, :cimd_fetch) do
      :ok
    else
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp rate_limit(url, _existing) do
    case RateLimiter.hit(
           "cimd:refresh:" <> host_of(url),
           @window_ms,
           @refresh_limit,
           :cimd_fetch
         ) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp host_of(url), do: URI.parse(url).host || "unknown"

  # THE binding. Everything else is metadata; this is what ties the document to
  # the URL, and therefore the client's identity to a host only its vendor can
  # serve from.
  defp validate_document(%{"client_id" => id}, url) when id != url,
    do: {:error, :client_id_mismatch}

  defp validate_document(document, _url) do
    cond do
      not is_map_key(document, "client_id") ->
        {:error, :client_id_mismatch}

      not valid_redirect_uris?(document["redirect_uris"]) ->
        {:error, :missing_redirect_uris}

      # A CIMD client never registered, so no secret was ever minted for it. If we
      # honoured a confidential method the client could never authenticate (its
      # stored hash is nil), and if we silently downgraded to `none` the client
      # would keep sending a secret that `authenticate_client/2` must then reject
      # for being present at all. Both failures are opaque; refusing the document
      # is legible.
      document["token_endpoint_auth_method"] not in [nil, "none"] ->
        {:error, :confidential_not_supported}

      true ->
        :ok
    end
  end

  defp valid_redirect_uris?([_ | _] = uris), do: Enum.all?(uris, &is_binary/1)
  defp valid_redirect_uris?(_), do: false

  defp store(url, document, existing) do
    changeset = Client.cimd_changeset(existing || %Client{}, url, document)

    if existing do
      case Repo.update(changeset, skip_tenant_check: true) do
        {:ok, client} -> {:ok, client}
        {:error, _changeset} -> {:error, :invalid_document}
      end
    else
      insert_new(changeset, url)
    end
  end

  # Two concurrent first-contact authorizes for the same new client both miss the
  # read and both insert. The partial unique index makes one lose; the loser
  # re-reads the winner's row rather than failing the authorization. Resolving by
  # re-read instead of `on_conflict:` is deliberate — ON CONFLICT cannot infer a
  # *partial* index from a bare column list, and the unsafe-fragment form needed
  # to spell the predicate out is easy to get subtly wrong.
  defp insert_new(changeset, url) do
    case Repo.insert(changeset, skip_tenant_check: true) do
      {:ok, client} ->
        {:ok, client}

      {:error, %Ecto.Changeset{} = failed} ->
        if Keyword.has_key?(failed.errors, :cimd_url),
          do: get_by_url(url) |> normalize_race_result(),
          else: {:error, :invalid_document}
    end
  end

  defp normalize_race_result({:ok, client}), do: {:ok, client}
  defp normalize_race_result({:error, :not_found}), do: {:error, :invalid_document}

  # Host only, never the full URL or the reason's payload: `:lifecycle` ships to
  # Loki (`:auth` info does not — see Engram.Logger.Category), and the host is
  # all the classification needs. This is the tripwire for "CIMD was advertised
  # and something on the new path is refusing real clients".
  defp log(event, url, reason) do
    Logger.warning(
      event,
      Metadata.with_category(:warning, :lifecycle,
        cimd_host: URI.parse(url).host,
        reason: inspect(reason)
      )
    )
  end
end
