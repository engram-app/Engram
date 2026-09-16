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
  alias Engram.OAuth
  alias Engram.OAuth.Cimd.Fetcher
  alias Engram.OAuth.Client
  alias Engram.Repo
  alias EngramWeb.RateLimiter

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
          | :missing_client_name
          | :confidential_not_supported
          | :jwks_uri_required
          | :jwks_uri_unfetchable
          | :no_supported_grant_type
          | :no_supported_response_type
          | :body_too_large
          | :not_json
          | :invalid_json
          | {:invalid_document, keyword()}
          | :store_conflict
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
         {:ok, negotiated} <- negotiate(document),
         {:ok, client} <- store(url, negotiated, existing) do
      {:ok, client}
    else
      {:error, reason} ->
        log_unless_rate_limited("mcp_cimd_rejected", url, reason)
        {:error, reason}
    end
  end

  # Capability metadata is NEGOTIATED, not enforced.
  #
  # `validate_document/2` above is about safety and binding, and it refuses.
  # This is about what the two ends can do together, and it intersects. The
  # distinction is the whole lesson of the 2026-08-04 incident: a fetched
  # document was being run through `Client.registration_changeset/2`, which is
  # DCR *registration policy* — subset allowlists, size caps, https-only
  # decoration. Those are the right questions to ask an anonymous stranger
  # POSTing to `/oauth/register`. They are the wrong questions to ask a document
  # a vendor published for every authorization server in existence, and asking
  # them cost every Claude user their connector over metadata we simply had no
  # use for.
  #
  # RFC 7591 §3.2.1 is explicit that the server records what IT supports and
  # reports back what it granted, rather than failing the registration.
  #
  # Redirect URIs are deliberately NOT negotiated here — they stay under the
  # shared changeset validation, because an unsafe redirect is a code-leak
  # vector, not a capability we can politely decline.
  #
  # KNOWN RESIDUAL: `validate_length(:redirect_uris, max: 10)` is DCR anti-abuse
  # policy, not safety, and it still hard-rejects — so the split below is not
  # total. A vendor publishing an eleventh redirect loses its connector the same
  # way an extra grant_type used to. Left as-is on purpose: silently dropping the
  # overflow could discard the very URI in use and fail later and worse, and the
  # bound is already redundant for CIMD (the body is capped mid-stream). Revisit
  # if a real document ever approaches it — Claude's publishes two.
  defp negotiate(document) do
    with {:ok, grants} <-
           intersect(
             document["grant_types"],
             Client.supported_grant_types(),
             :no_supported_grant_type
           ),
         {:ok, responses} <-
           intersect(
             document["response_types"],
             Client.supported_response_types(),
             :no_supported_response_type
           ) do
      {:ok,
       document
       |> Map.put("grant_types", grants)
       |> Map.put("response_types", responses)
       |> Map.put("client_name", truncate_name(document["client_name"]))
       |> drop_undisplayable_uris()}
    end
  end

  # Absent or malformed means "unstated", which the changeset's own defaults
  # answer. Only an explicit list that shares nothing with us is fatal: at that
  # point there is no flow left to run, and the refusal is a statement about us
  # rather than about tidiness.
  defp intersect(declared, supported, empty_error) when is_list(declared) do
    case Enum.filter(supported, &(&1 in declared)) do
      [] -> {:error, empty_error}
      kept -> {:ok, kept}
    end
  end

  defp intersect(_declared, _supported, _empty_error), do: {:ok, nil}

  defp truncate_name(name) when is_binary(name),
    do: String.slice(name, 0, Client.client_name_max_length())

  defp truncate_name(other), do: other

  defp drop_undisplayable_uris(document) do
    Enum.reduce(Client.metadata_uri_fields(), document, fn field, acc ->
      key = Atom.to_string(field)

      if Map.has_key?(acc, key) and not Client.displayable_metadata_uri?(acc[key]),
        do: Map.put(acc, key, nil),
        else: acc
    end)
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

  @doc """
  The host of a URL, or `"unknown"`.

  Public because it is the one host renderer for the whole OAuth tree: the
  rate-limit buckets here, `Engram.OAuth.log_refusal/3`, and
  `Engram.OAuth.Cimd.JwksCache`'s buckets all key on it. It existed five times,
  and the copy inside this module's own logger had dropped the `|| "unknown"`
  fallback — so one emitter could write `cimd_host: nil` into the field the
  `mcp-connector-refused` alert facets on while every sibling wrote `"unknown"`.

  Guard-narrowed rather than `URI.parse(url).host || "unknown"`: dialyzer
  cannot prove the `||` discharges the `nil` in `%URI{}.host`, and it runs with
  `:missing_range` here. Widening the spec to `String.t() | nil` would be the
  wrong repair — a nil in this field is the drift this function exists to end.
  """
  @spec host_of(String.t()) :: String.t()
  def host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _no_host -> "unknown"
    end
  end

  # THE binding. Everything else is metadata; this is what ties the document to
  # the URL, and therefore the client's identity to a host only its vendor can
  # serve from.
  @doc """
  Decides whether a fetched document is one we would accept, without storing it.

  Public because vendor acceptance needs a check of its own. The conformance
  suite only proves that *MCPJam* can register, since `--registration cimd`
  supplies MCPJam's own published document and no other vendor's is ever
  fetched — so a vendor changing its auth method turns nothing red. That is how
  ChatGPT stayed unable to connect for weeks under a green nightly run (#1635).

  Calling this against a real vendor's published document needs no database, no
  deployed target and no MCPJam, which is what lets the check gate rather than
  merely report.
  """
  @spec validate_document(map(), String.t()) :: :ok | {:error, reason()}
  def validate_document(%{"client_id" => id}, url) when id != url,
    do: {:error, :client_id_mismatch}

  def validate_document(document, _url) do
    cond do
      not is_map_key(document, "client_id") ->
        {:error, :client_id_mismatch}

      not valid_redirect_uris?(document["redirect_uris"]) ->
        {:error, :missing_redirect_uris}

      # MCP 2025-11-25: "The metadata document MUST include at least the
      # following properties: client_id, client_name, redirect_uris." We enforced
      # two of the three.
      #
      # This is a required field, not capability metadata, so it belongs here
      # with the refusals rather than in negotiate/1 — but the line is worth
      # drawing carefully given how this PR started. An unknown grant_type costs
      # us nothing to ignore; a nameless client cannot be rendered on the consent
      # screen at all, and "Authorize this app" is a worse outcome than a legible
      # refusal. Both real documents in the test suite supply it, as does every
      # client that reads the spec.
      not valid_client_name?(document["client_name"]) ->
        {:error, :missing_client_name}

      # `private_key_jwt` authenticates with a signature, not a secret, so the
      # reasoning below does not reach it: there is nothing to mint. The signing
      # key comes from the document's own `jwks_uri`, which is bound to a host
      # only the vendor can serve from — the same argument that binds the
      # document itself. Without that URI there is no way to verify anything, so
      # the method is unusable and the refusal is about the document, not us.
      #
      # Refusing this outright is what made ChatGPT unable to connect at all
      # until 2026-09-15; it declares `private_key_jwt` and never negotiates down
      # even though we advertise `none` first (#1633).
      #
      # Both `jwks_uri` arms read the PERMITTED set, matching how the token
      # endpoint routes. Keying on the preferred method let a document
      # preferring `none` while supporting `private_key_jwt` skip them
      # entirely, then present assertions against a key location we had never
      # checked.
      Client.document_permits_assertion?(document) and
          not Client.displayable_metadata_uri?(document["jwks_uri"]) ->
        {:error, :jwks_uri_required}

      # This required the same ORIGIN until 2026-09-15, to stop a document at
      # `vendor.example` naming keys anywhere and converting a host binding
      # into an unbounded delegation. Two things were wrong with that.
      #
      # It refused a vendor serving keys from a CDN or a dedicated key host,
      # which is ordinary practice and which the CIMD draft nowhere forbids —
      # and the refusal read as the vendor's bug, not ours.
      #
      # And the delegation it prevented is one the VENDOR chose. Setting
      # `jwks_uri` at all requires serving the document at the `client_id` URL,
      # so an attacker who can point it anywhere already controls the vendor's
      # own host and needs none of this. The residual risk is to the vendor's
      # keys, and it is theirs to take; it is not a risk to our users, who
      # still cannot have a token minted without an auth code they consented to.
      #
      # What must still hold is that the URI is one we can actually fetch when
      # a token exchange arrives. `validate_url/1` is the same rule the fetch
      # applies, minus the DNS lookup, so a scheme, port or shape the guard
      # would refuse is caught here — legibly, at authorize — instead of as a
      # mystery 401 on every later exchange. An unfetchable URI that skipped
      # this check does not fail loudly later: `SsrfGuard` refuses it at the
      # transport, `jwks.ex` maps that to `:jwks_unavailable`, and that reason
      # is TRANSIENT, so the connector retries a permanent misconfiguration
      # forever. DNS stays out on purpose: a resolver blip must not become a
      # permanent verdict on the document.
      Client.document_permits_assertion?(document) and
          SsrfGuard.validate_url(document["jwks_uri"]) != :ok ->
        {:error, :jwks_uri_unfetchable}

      # A secret-based method still refuses. A CIMD client never registered, so
      # no secret was ever minted for it. If we honoured the method the client
      # could never authenticate (its stored hash is nil), and if we silently
      # downgraded to `none` the client would keep sending a secret that
      # `authenticate_client/3` must then reject for being present at all. Both
      # failures are opaque; refusing the document is legible.
      #
      # Read off the permitted SET, matching how the token endpoint routes. The
      # preference alone was read as a requirement until #1634, so a document
      # naming `client_secret_basic` first was refused terminally even when it
      # also permitted `private_key_jwt` or `none`, both of which we implement.
      # Same "preference treated as a requirement" defect as #1633/#1639/#1640,
      # pointing a third way.
      #
      # Empty is the only refusal left, and it is a real one: every method the
      # document permits would need a secret it never received.
      # `Client.cimd_changeset/3` stores a member of this same set, so whatever
      # passes here is what the token endpoint later routes on.
      Client.document_permitted_auth_methods(document) == [] ->
        {:error, :confidential_not_supported}

      true ->
        :ok
    end
  end

  defp valid_redirect_uris?([_ | _] = uris), do: Enum.all?(uris, &is_binary/1)
  defp valid_redirect_uris?(_), do: false

  # Whitespace-only is absent with extra steps — it renders as nothing on the
  # consent screen, which is the whole reason the field is required.
  defp valid_client_name?(name) when is_binary(name), do: String.trim(name) != ""
  defp valid_client_name?(_), do: false

  defp store(url, document, existing) do
    changeset = Client.cimd_changeset(existing || %Client{}, url, document)

    if existing do
      case Repo.update(changeset, skip_tenant_check: true) do
        {:ok, client} -> {:ok, client}
        {:error, failed} -> {:error, {:invalid_document, failed.errors}}
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
          else: {:error, {:invalid_document, failed.errors}}
    end
  end

  defp normalize_race_result({:ok, client}), do: {:ok, client}

  # Losing the insert race and then not finding the winner is OUR problem, not a
  # statement about the vendor's document — the caller must be able to tell them
  # apart, because one is retryable and the other is terminal.
  defp normalize_race_result({:error, :not_found}), do: {:error, :store_conflict}

  # Host only, never the full URL or the reason's payload: `:lifecycle` ships to
  # Loki (`:auth` info does not — see Engram.Logger.Category), and the host is
  # all the classification needs. This is the tripwire for "CIMD was advertised
  # and something on the new path is refusing real clients".
  defp log(event, url, reason), do: OAuth.log_refusal(event, url, reason)
end
