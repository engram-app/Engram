defmodule Engram.OAuth do
  @moduledoc """
  High-level context for the OAuth 2.1 authorization server.

  Today: DCR (RFC 7591) + authorization-code minting (RFC 6749 §4.1 with
  PKCE per RFC 7636). Phases 4-6 add token exchange and revocation.

  `oauth_clients` and `oauth_authorization_codes` are intentionally not
  RLS-tenanted — the former is shared (clients self-register pre-login),
  the latter is keyed by hashed code value and looked up before any
  user identity is established (token exchange comes from the client,
  not the user).
  """
  import Ecto.Query
  alias Engram.Accounts
  alias Engram.Analytics.McpClient
  alias Engram.Logger.Metadata
  alias Engram.OAuth.{AuthorizationCode, Cimd, Client, RefreshToken}
  alias Engram.Repo

  require Logger

  @authorization_code_prefix "engram_ac_"
  @code_ttl_seconds 600
  @max_state_bytes 2048
  @refresh_token_prefix "engram_oauth_rt_"
  @refresh_token_ttl_days 90
  # One byte count, not three: every prefixed random token this module mints is
  # 32 bytes of CSPRNG output, and three attributes holding 32 invited them to
  # drift into three different strengths.
  @token_bytes 32
  @valid_scopes ~w(mcp)
  @max_requested_scopes 16

  # ── Clients (Phase 2) ────────────────────────────────────────────

  @client_secret_prefix "engram_oauth_cs_"

  @doc """
  Registers a DCR client.

  A confidential registration (`client_secret_post` / `client_secret_basic`)
  mints a secret here rather than in the changeset, because the plaintext must
  reach the caller exactly once while only its hash is stored. The returned
  struct carries the plaintext on the virtual `:client_secret` field; reloading
  the row later yields `nil` there, by design.
  """
  def register_client(attrs) do
    changeset = Client.registration_changeset(%Client{}, attrs)
    secret = mint_client_secret(Ecto.Changeset.get_field(changeset, :token_endpoint_auth_method))

    changeset
    |> maybe_put_secret_hash(secret)
    |> Repo.insert(skip_tenant_check: true)
    |> case do
      {:ok, client} -> {:ok, %{client | client_secret: secret}}
      other -> other
    end
  end

  defp mint_client_secret(method) do
    if Client.confidential?(method), do: mint_token(@client_secret_prefix)
  end

  defp maybe_put_secret_hash(changeset, nil), do: changeset

  defp maybe_put_secret_hash(changeset, secret),
    do: Ecto.Changeset.put_change(changeset, :client_secret_hash, hash_code(secret))

  @doc """
  Looks up a client by its **wire** `client_id`, which is either a DCR UUID or a
  CIMD metadata-document URL.

  Pure database lookup — no network I/O, deliberately. Only
  `validate_authorization_request/1` may fetch a document
  (`Engram.OAuth.Cimd.ensure_client/1`); the token, refresh and revoke paths
  resolve an already-known CIMD client without reaching out to its vendor.
  """
  def get_client(client_id) when is_binary(client_id) do
    case Ecto.UUID.cast(client_id) do
      {:ok, _} ->
        case Repo.one(from(c in Client, where: c.client_id == ^client_id),
               skip_tenant_check: true
             ) do
          nil -> {:error, :not_found}
          client -> {:ok, client}
        end

      # Not a UUID. A CIMD client's wire id is an HTTPS URL, resolved against the
      # `cimd_url` column; the primary key stays internal. Anything else is
      # simply unknown.
      :error ->
        if Cimd.url_shaped?(client_id),
          do: Cimd.get_by_url(client_id),
          else: {:error, :not_found}
    end
  end

  def get_client(_), do: {:error, :not_found}

  # Wire client_id -> internal UUID.
  #
  # Everything downstream of authorization stores and compares the internal UUID:
  # `oauth_authorization_codes.client_id` and `oauth_refresh_tokens.client_id` are
  # uuid columns. A CIMD client, though, presents its URL on every token,
  # refresh and revoke request, so a bare `==` against the stored value fails for
  # the legitimate client. Normalizing at each of those boundaries is what makes
  # the URL a wire-only concern.
  #
  # The two-argument form short-circuits when the caller already knows the stored
  # value and it matches — the DCR case, which must not pay for a query.
  defp internal_client_id(wire_id, known) when wire_id == known, do: known
  defp internal_client_id(wire_id, _known), do: internal_client_id(wire_id)

  defp internal_client_id(wire_id) do
    case get_client(wire_id) do
      {:ok, %Client{client_id: id}} -> id
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Authenticates the client on a token request, per RFC 6749 §3.2.1.

  The registered `token_endpoint_auth_method` binds in BOTH directions: a
  confidential client must present its secret, and a client registered `none`
  must not. Accepting a secret from a public client would make the registered
  method decorative and mask a confused or probing caller.

  `secret` is whatever the caller supplied (HTTP Basic or request body), or
  `nil`. Comparison is constant-time against the stored hash.
  """
  @spec authenticate_client(String.t() | nil, String.t() | nil) ::
          :ok | {:error, :invalid_client | :temporarily_unavailable}
  def authenticate_client(client_id, secret), do: authenticate_client(client_id, secret, [])

  @doc """
  As `authenticate_client/2`, plus RFC 7523 `private_key_jwt` support.

  Opts:
    * `:assertion` — the raw `client_assertion`, when one was presented.
    * `:audiences` — values acceptable in the assertion's `aud` claim.

  The registered method still binds in both directions. An assertion-based
  client MUST present an assertion and MUST NOT present a secret; a client
  registered `none` must present neither. Letting a caller pick its own
  authentication method at token time would make the registered one decorative.
  """
  @spec authenticate_client(String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, :invalid_client | :temporarily_unavailable}
  def authenticate_client(client_id, secret, opts) do
    case get_client(client_id) do
      {:ok, client} ->
        check_client_credentials(client, secret, opts)

      # Indistinguishable from a bad secret ON THE WIRE, on purpose. Our own
      # logs are the one place the two must be told apart.
      {:error, :not_found} ->
        reject_client(client_id, :client_unknown)
    end
  end

  defp check_client_credentials(client, secret, opts) do
    cond do
      # The PERMITTED set, not the preferred method. Reading the preference here
      # refused a valid assertion from any document that merely prefers `none`
      # while also supporting `private_key_jwt` — the mirror of the bug #1639
      # fixed, and the reason both directions now derive from one function.
      Client.assertion_permitted?(client) ->
        check_client_assertion(client, secret, opts)

      # An assertion presented to a client that does not authenticate that way.
      # Accepting it would wave through a caller that believes it proved
      # something — the same reason an unrecognised `client_assertion_type` is
      # refused rather than ignored. It also surfaces the deploy window: for up
      # to the document TTL after release, an existing row may still say `none`.
      not is_nil(Keyword.get(opts, :assertion)) ->
        reject_assertion(client, :assertion_not_expected)

      true ->
        check_client_secret(client, secret)
    end
  end

  defp check_client_assertion(client, secret, opts) do
    assertion = Keyword.get(opts, :assertion)

    cond do
      not is_nil(secret) ->
        reject_assertion(client, :secret_presented_with_assertion)

      # A document declares a PREFERRED method and a permitted SET. ChatGPT
      # publishes `private_key_jwt` as the former and lists `none` in the
      # latter, then exchanges as a public client over PKCE — which its own
      # document allows. Treating the preference as a requirement made that a
      # terminal `invalid_client`, so the connector got one step further than
      # the original bug and still died (#1633 follow-up).
      #
      # This reads the vendor's host-bound document, not the request, so a
      # caller still cannot pick its own method. PKCE is enforced on the
      # exchange either way.
      is_nil(assertion) and Client.public_auth_permitted?(client) ->
        :ok

      is_nil(assertion) ->
        reject_assertion(client, :assertion_missing)

      true ->
        run_assertion_verification(client, assertion, opts)
    end
  end

  defp run_assertion_verification(client, assertion, opts) do
    case Cimd.Jwks.verify_assertion(client, assertion, Keyword.get(opts, :audiences, [])) do
      :ok -> :ok
      {:error, reason} -> reject_assertion(client, reason)
    end
  end

  # ONE place that turns an assertion refusal into a response, so no branch can
  # be added silently later. Two things make the line actionable:
  #
  #   * the host — "some assertion failed" cannot be triaged; "chatgpt.com's
  #     assertions fail with :alg_pin_mismatch" can. `Engram.OAuth.Cimd.log/3`
  #     carries the same label for the same reason.
  #   * the transient split — a throttle or an unreachable JWKS endpoint is OUR
  #     side of the wire and clears on its own. RFC 6749 §5.2 makes
  #     `invalid_client` terminal, so reporting one as the other hands the
  #     connector a permanent failure for a condition that fixes itself.
  defp reject_assertion(client, reason) do
    log_refusal("oauth_client_assertion_rejected", client, reason)

    if Cimd.Jwks.transient?(reason),
      do: {:error, :temporarily_unavailable},
      else: {:error, :invalid_client}
  end

  @doc """
  Logs a non-assertion client refusal, then returns the terminal error.

  The sibling of `reject_assertion/2`, and for the same reason: every refusal on
  the connect path needs exactly one line, because `mcp-connector-refused`
  matches by MESSAGE and a branch that logs nothing is unreachable by any
  filter. Five branches logged nothing — an unknown `client_id` on the token and
  authorize paths, all three secret outcomes, and the controller's
  Basic-vs-body conflict — so a vendor with a typo'd id or a stale secret 401'd
  forever and produced no attributable signal. That is #1633's failure mode one
  branch over (#1643).

  Public because `EngramWeb.OAuthTokenController` refuses one credential shape
  before this module is ever reached, and a second helper there would be a
  second taxonomy to keep in sync with the alert filter.
  """
  @spec reject_client(Client.t() | String.t() | nil, atom()) :: {:error, :invalid_client}
  def reject_client(subject, reason) do
    log_client_rejection(subject, reason)
    {:error, :invalid_client}
  end

  defp log_client_rejection(subject, reason),
    do: log_refusal("oauth_client_rejected", subject, reason)

  @doc """
  THE emitter for every refusal on the connect path. One metadata shape, so the
  four message names cannot drift apart.

  They already had. Five emitters across four modules each rebuilt this line by
  hand, and two had diverged: `Cimd.log/3` omitted the `|| "unknown"` host
  fallback, so it could emit `cimd_host: nil` where its siblings emit
  `"unknown"` — two shapes for the one field `mcp-connector-refused` facets on —
  and the token controller's copy carried no `cimd_host` key at all, so a
  host-faceted alert silently dropped every malformed-assertion refusal. The
  message name stays the caller's choice (the alert filter enumerates them, and
  "malformed" and "rejected" are different diagnoses); the SHAPE does not.

  `subject` is whatever identifies the vendor — a `%Client{}`, a wire
  `client_id`, a document or `jwks_uri` URL, or `nil`. Only its host is logged:
  a CIMD `client_id` is a URL supplied by an unauthenticated caller, so logging
  it whole is an unbounded value in a log field, and a DCR id is an opaque UUID
  with no triage value.

  `extra` appends caller-specific fields. The token endpoint adds `error_code`,
  `grant_type`, `user_agent` and a UUID-validated `client_id`. UUID-only keeps
  it bounded, and on a grant refusal the client has already authenticated, so
  the id names a row we can look up: the triage value an unverified id lacks.
  """
  @spec log_refusal(String.t(), Client.t() | String.t() | nil, term(), keyword()) :: :ok
  def log_refusal(event, subject, reason, extra \\ []) do
    Logger.warning(
      event,
      Metadata.with_category(
        :warning,
        :lifecycle,
        [cimd_host: refusal_host(subject), reason: refusal_reason(reason)] ++ extra
      )
    )
  end

  # Field NAMES, never the changeset messages. Several of those interpolate the
  # offending value (`"missing scheme: #{uri}"`), which is attacker-supplied on
  # an unauthenticated endpoint — the same reason the host, not the URL, is
  # logged. The names are ours, and they are the whole diagnosis: on 2026-08-04
  # a bare `:invalid_document` left us unable to say which field of a vendor's
  # document had killed every Claude connection. `Metadata.safe_reason/1`
  # renders this tuple as a bare ":invalid_document", which is why the clause
  # has to come first.
  defp refusal_reason({:invalid_document, errors}),
    do: "invalid_document fields=#{inspect(errors |> Keyword.keys() |> Enum.uniq())}"

  # The STATUS, not just the tag. `Metadata.safe_reason/1`'s generic tuple
  # clause renders only the tag, which would make a vendor serving 404 (wrong
  # path), 403 (blocked) and 503 (down) for its document indistinguishable —
  # in the telemetry that exists to tell them apart. An HTTP status cannot
  # carry user data, so rendering it is safe.
  defp refusal_reason({:http_status, status}) when is_integer(status),
    do: "http_status #{status}"

  defp refusal_reason(reason), do: Metadata.safe_reason(reason)

  defp refusal_host(%Client{cimd_url: url}) when is_binary(url), do: Cimd.host_of(url)
  defp refusal_host(%Client{}), do: "unknown"

  defp refusal_host(id) when is_binary(id) do
    if Cimd.url_shaped?(id), do: Cimd.host_of(id), else: "unknown"
  end

  defp refusal_host(_subject), do: "unknown"

  # The three secret outcomes are reported apart because they are three
  # different diagnoses: the vendor sent the wrong thing, the vendor sent
  # nothing, or OUR row has no hash to compare against. Collapsing them is what
  # made a stale secret and a broken registration look identical in Loki.
  defp check_client_secret(client, secret) do
    cond do
      not Client.confidential?(client.token_endpoint_auth_method) ->
        if is_nil(secret),
          do: :ok,
          else: reject_client(client, :secret_presented_by_public_client)

      is_nil(secret) ->
        reject_client(client, :secret_missing)

      is_nil(client.client_secret_hash) ->
        reject_client(client, :secret_unset_on_client)

      Plug.Crypto.secure_compare(hash_code(secret), client.client_secret_hash) ->
        :ok

      true ->
        reject_client(client, :secret_mismatch)
    end
  end

  # ── Authorization codes (Phase 3) ────────────────────────────────

  @doc """
  Validates the params of an `/oauth/authorize` request per RFC 6749 §4.1.1.

  Returns:
    * `{:ok, validated}` — map of params safe to round-trip into the consent UI
    * `{:redirect_error, redirect_uri, error_code, state}` — bad post-client
      params; caller should 302 to the redirect_uri with `error` query param
    * `{:client_error, code}` — bad client_id or redirect_uri; render an HTML
      error page rather than redirect (a redirect would let an attacker
      exfiltrate codes via a forged redirect_uri)
    * `{:server_error, code}` — we could not resolve a CIMD client for a reason
      that is ours and transient. Same "render, never redirect" rule (there is
      no validated redirect_uri to trust yet), but a 503 rather than a 400, so
      the client retries instead of writing the connector off.
  """
  def validate_authorization_request(params) when is_map(params) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, redirect_uri} <- match_redirect_uri(client, params["redirect_uri"]),
         :ok <- check_response_type(params, redirect_uri),
         :ok <- check_pkce(params, redirect_uri),
         :ok <- check_state_length(params) do
      {granted, requested} = narrow_scope(params["scope"])

      {:ok,
       %{
         client: client,
         client_id: client.client_id,
         client_name: client.client_name,
         redirect_uri: redirect_uri,
         code_challenge: params["code_challenge"],
         code_challenge_method: params["code_challenge_method"] || "S256",
         scope: granted,
         scope_requested: requested,
         state: params["state"]
       }}
    end
  end

  def validate_authorization_request(_), do: {:client_error, "invalid_request"}

  # RFC 6749 puts no bound on `state`, and clients legitimately pack routing
  # data into it (Windsurf's exceeded 255 and 500'd us on 2026-07-30, because
  # the column was varchar(255)). The column is `text` now, but "no column
  # limit" must not become "unbounded storage": consent is reachable by any
  # signed-in user and a code row lives for the full TTL. 2048 is generous
  # enough for every real client and still bounded.
  #
  # A `client_error` rather than a redirect: bouncing an oversized state back
  # through the redirect would just move the problem to the client's URL parser.
  defp check_state_length(%{"state" => state}) when is_binary(state) do
    if byte_size(state) > @max_state_bytes,
      do: {:client_error, "invalid_request"},
      else: :ok
  end

  defp check_state_length(_), do: :ok

  @doc """
  Reads a vault selection off consent params.

  `vault_ids` is the current shape. `vault_choice` ("vault:<id>" | "vault:*")
  is the pre-multi-vault shape and is still accepted for one release so an
  SPA cached across the deploy keeps working; `vault_ids` wins when both are
  present. Absent params default to `:all`, matching the previous
  `params["vault_choice"] || "vault:*"` behaviour.
  """
  @spec parse_vault_selection(map()) :: :all | [String.t()] | :invalid
  def parse_vault_selection(%{"vault_ids" => ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: ids, else: :invalid
  end

  def parse_vault_selection(%{"vault_ids" => _}), do: :invalid
  def parse_vault_selection(%{"vault_choice" => "vault:*"}), do: :all
  def parse_vault_selection(%{"vault_choice" => "vault:" <> id}), do: [id]
  def parse_vault_selection(%{"vault_choice" => _}), do: :invalid
  def parse_vault_selection(_), do: :all

  @doc """
  Mints an authorization code for a validated request + a vault selection.

  `vault_selection` is `:all` or a list of vault id strings. Ownership is
  verified for every id — a user cannot grant an OAuth client access to a
  vault they do not own, and one bad id rejects the whole grant.

  `label` is the optional free-text name the user typed on the consent
  screen. An unusable one is rejected on the same `access_denied` path as a
  bad vault id, so the consent screen has one rejection shape.

  Returns `{:ok, redirect_url}` (caller 302s) or
  `{:redirect_error, redirect_uri, error_code, state}`.
  """
  def mint_authorization_code(user, validated, vault_selection, label) do
    with {:ok, vault_ids} <- resolve_vaults(user, vault_selection),
         {:ok, label} <- resolve_label(label) do
      raw_code = mint_token(@authorization_code_prefix)

      attrs = %{
        code_hash: hash_code(raw_code),
        client_id: validated.client_id,
        user_id: user.id,
        redirect_uri: validated.redirect_uri,
        code_challenge: validated.code_challenge,
        code_challenge_method: validated.code_challenge_method,
        scope: validated.scope,
        vault_id: scalar_vault_id(vault_ids),
        vault_ids: vault_ids,
        label: label,
        state: validated.state,
        expires_at: expires_in(@code_ttl_seconds)
      }

      case %AuthorizationCode{}
           |> AuthorizationCode.changeset(attrs)
           |> Repo.insert(skip_tenant_check: true) do
        {:ok, _row} ->
          {:ok, build_redirect(validated.redirect_uri, %{code: raw_code, state: validated.state})}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      :error ->
        {:redirect_error, validated.redirect_uri, "access_denied", validated.state}
    end
  end

  @doc """
  Looks up an authorization code by its raw value — used by tests + by
  the Phase 4 `/oauth/token` exchange.
  """
  def get_authorization_code_by_raw(raw_code) when is_binary(raw_code) do
    hash = hash_code(raw_code)

    case Repo.one(from(ac in AuthorizationCode, where: ac.code_hash == ^hash),
           skip_tenant_check: true
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # ── Token exchange (Phase 4) ─────────────────────────────────────

  @doc """
  Exchanges an authorization code for an access + refresh token pair.
  Validates: code exists, unconsumed, unexpired, matching client_id,
  matching redirect_uri, PKCE verifier hashes to stored challenge.

  A refusal is `{:error, {:invalid_grant, grant_reason()}}`.
  """
  def exchange_authorization_code(params, opts \\ []) do
    ip = Keyword.get(opts, :ip)

    with {:ok, code_row} <- find_unconsumed_code(params["code"]),
         :ok <- check_code_client(code_row, params["client_id"]),
         :ok <- check_code_redirect_uri(code_row, params["redirect_uri"]),
         :ok <- check_pkce_verifier(code_row, params["code_verifier"]),
         {:ok, user} <- fetch_user(code_row.user_id),
         :ok <- consume_code(code_row),
         {:ok, refresh_raw, refresh_row} <-
           insert_refresh_token(grant_attrs(code_row, Ecto.UUID.generate(), ip)) do
      {:ok, build_token_response(user, code_row, refresh_raw, refresh_row)}
    end
  end

  # How long after a refresh token is consumed a replay of it may still
  # re-issue (see grace_reissue/2). Long enough for a client to time out and
  # retry once; short enough that a stolen token is useless soon after.
  @refresh_reuse_grace_seconds 60

  @doc """
  Rotates a refresh token: marks the presented one consumed, mints + issues
  a successor in the same family. If the presented token is already
  consumed (replay) or revoked, this revokes the entire family per
  RFC 6749 §10.4. A refusal is `{:error, {:invalid_grant, grant_reason()}}`.
  """
  def rotate_refresh_token(raw_token, client_id, opts \\ []) do
    ip = Keyword.get(opts, :ip)

    case refresh_token_by_raw(raw_token) do
      nil ->
        grant_error(:refresh_token_unknown)

      %RefreshToken{} = rt ->
        put_grant_user_id(rt.user_id)
        rotate_existing(rt, internal_client_id(client_id, rt.client_id), ip)
    end
  end

  # The sibling of `get_authorization_code_by_raw/1`. The rotate and revoke
  # paths both resolve a raw refresh token, and had a copy each — so a future
  # scoping predicate would have landed on one and missed the other.
  #
  # Returns the row or nil rather than an {:ok, _} | {:error, _} pair: both
  # callers branch on absence directly (revocation must stay nil-tolerant per
  # RFC 7009 §2.2), so a wrapper would only be unwrapped twice.
  defp refresh_token_by_raw(raw_token) do
    hash = hash_code(raw_token)
    Repo.one(from(rt in RefreshToken, where: rt.token_hash == ^hash), skip_tenant_check: true)
  end

  # Every decision about a refresh token is made in ONE transaction, holding
  # `FOR UPDATE` on the presented row (third review of #1974). That one lock is
  # the whole concurrency story:
  #
  #   * two rotations of the same token serialize, so the second sees the first
  #     one's result instead of racing it (no compare-and-set, no lost race);
  #   * a revoke (`revoke_refresh_tokens/1`, used by every Disconnect path)
  #     takes `FOR UPDATE` on the live rows it is about to revoke, the presented
  #     row included, before it updates. Whichever commits first, the other sees
  #     it: a rotation that wins has its successor revoked by the revoke's later
  #     UPDATE, and a revoke that wins is seen by the rotation under its lock.
  #
  # A refusal that revokes (reuse) must commit, so the transaction returns the
  # result instead of rolling back. Logging and analytics run after it.
  defp rotate_existing(%RefreshToken{client_id: actual}, requested, _ip) when actual != requested,
    do: grant_error(:client_mismatch)

  defp rotate_existing(%RefreshToken{} = rt, _client_id, ip) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case lock_row(rt) do
          nil -> {:error, :refresh_token_unknown}
          locked -> decide(locked, ip)
        end
      end)

    report(outcome, rt)
  end

  defp report({:ok, response}, _rt), do: {:ok, response}

  defp report({:ok, response, {:grace, ip_matched}}, rt) do
    log_reuse(rt, within_grace: true, ip_matched: ip_matched)
    {:ok, response}
  end

  defp report({:error, :refresh_token_reuse}, rt) do
    log_reuse(rt, within_grace: false)
    grant_error(:refresh_token_reuse)
  end

  defp report({:error, reason}, _rt), do: grant_error(reason)

  # Revoked: Disconnect, RFC 7009 or an earlier replay. Not a theft signal in
  # itself, so it is reported as revoked and never logged as reuse.
  defp decide(%RefreshToken{revoked_at: %DateTime{}} = rt, _ip) do
    revoke_family(rt.family_id)
    {:error, :refresh_token_revoked}
  end

  defp decide(%RefreshToken{consumed_at: %DateTime{} = at} = rt, ip) do
    with true <- DateTime.diff(DateTime.utc_now(), at) <= @refresh_reuse_grace_seconds,
         {:ok, response, ip_matched} <- grace_reissue(rt, ip) do
      {:ok, response, {:grace, ip_matched}}
    else
      _not_eligible ->
        revoke_family(rt.family_id)
        {:error, :refresh_token_reuse}
    end
  end

  defp decide(%RefreshToken{expires_at: exp} = rt, ip) do
    if DateTime.compare(DateTime.utc_now(), exp) == :gt do
      {:error, :refresh_token_expired}
    else
      Repo.update_all(
        from(r in RefreshToken, where: r.id == ^rt.id),
        [set: [consumed_at: DateTime.utc_now(:second)]],
        skip_tenant_check: true
      )

      case mint_rotation_successor(rt, ip) do
        {:ok, response} -> {:ok, response}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp lock_row(rt) do
    Repo.one(from(r in RefreshToken, where: r.id == ^rt.id, lock: "FOR UPDATE"),
      skip_tenant_check: true
    )
  end

  # Inside rotate_existing/3's transaction, which undoes the insert when the
  # user lookup fails (it should not: the user_id FK guarantees the row).
  defp mint_rotation_successor(rt, ip) do
    {:ok, refresh_raw, refresh_row} = insert_refresh_token(grant_attrs(rt, rt.family_id, ip))

    with {:ok, user} <- fetch_user(rt.user_id) do
      {:ok, build_token_response(user, rt, refresh_raw, refresh_row)}
    end
  end

  defp revoke_family(family_id) do
    now = DateTime.utc_now(:second)

    from(rt in RefreshToken,
      where: rt.family_id == ^family_id and is_nil(rt.revoked_at)
    )
    |> Repo.update_all([set: [revoked_at: now]], skip_tenant_check: true)
  end

  @doc """
  Revokes the live refresh tokens `query` selects, safely against a rotation
  in flight: it first locks them (`FOR UPDATE`), which waits for any rotation
  holding one, then revokes with a fresh statement, whose snapshot includes a
  successor that rotation just committed. Every Disconnect path goes through
  this. `opts` are passed to both statements.
  """
  @spec revoke_refresh_tokens(Ecto.Queryable.t(), keyword()) :: {non_neg_integer(), nil}
  def revoke_refresh_tokens(query, opts \\ []) do
    live = from(t in query, where: is_nil(t.revoked_at))

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.all(from(t in live, select: t.id, lock: "FOR UPDATE"), opts)
        Repo.update_all(live, [set: [revoked_at: DateTime.utc_now(:second)]], opts)
      end)

    result
  end

  # #1974: a client whose rotation response was lost retries with the token it
  # still holds. Revoking the family for that killed the connection every
  # time a response went missing, and access tokens last 15 min.
  #
  # So inside the window, while nothing minted since has been USED (the client
  # cannot have received it, or it would have used it), the replay re-issues:
  # the live successor is revoked and a new one minted, so the family never
  # has two live tokens. Every duplicate inside the window is handled the same
  # way, so N racing retries all succeed instead of the third revoking the
  # family. Runs under rotate_existing/3's lock on the old token; the
  # successors are locked too, and the revoke must hit every live one it read.
  #
  # Not eligible (the caller revokes the family as reuse):
  #   * any successor was consumed: the client had it, so this is theft
  #   * no successor is still live: it was revoked some other way (RFC 7009,
  #     Disconnect), and a replay of its parent must not bring it back
  #
  # The raw successor cannot simply be returned again: only its hash is stored.
  #
  # The tradeoff (docs/context/mcp-oauth.md): inside the window whoever
  # presents the old token gets a new one. The client check (rotate_existing/3)
  # and client authentication (the token controller, before this runs) still
  # apply, every re-issue logs whether the caller's IP matched the original
  # rotation's, and a revoked successor turning up later revokes the family.
  defp grace_reissue(rt, ip) do
    successors =
      Repo.all(
        from(r in RefreshToken,
          where:
            r.family_id == ^rt.family_id and r.id != ^rt.id and r.inserted_at >= ^rt.consumed_at,
          lock: "FOR UPDATE"
        ),
        skip_tenant_check: true
      )

    live = Enum.filter(successors, &is_nil(&1.revoked_at))
    live_ids = Enum.map(live, & &1.id)

    with true <- Enum.all?(successors, &is_nil(&1.consumed_at)),
         true <- live != [],
         {n, _} when n == length(live) <- revoke_ids(live_ids),
         {:ok, response} <- mint_rotation_successor(rt, ip) do
      original = Enum.min_by(successors, & &1.inserted_at, DateTime)
      {:ok, response, original.last_used_ip == ip}
    else
      _ -> :not_eligible
    end
  end

  defp revoke_ids(ids) do
    from(r in RefreshToken,
      where: r.id in ^ids and is_nil(r.revoked_at) and is_nil(r.consumed_at)
    )
    |> Repo.update_all([set: [revoked_at: DateTime.utc_now(:second)]], skip_tenant_check: true)
  end

  defp log_reuse(rt, opts) do
    within_grace = Keyword.fetch!(opts, :within_grace)

    {family, _registration} =
      Client |> Repo.get(rt.client_id, skip_tenant_check: true) |> McpClient.of_client()

    Engram.Analytics.track(%Accounts.User{id: rt.user_id}, "mcp_oauth_refresh_reuse", %{
      within_grace: within_grace,
      client: family
    })

    # Strings: the text formatter drops `false` metadata entirely.
    metadata =
      [within_grace: to_string(within_grace), client_id: rt.client_id, family_id: rt.family_id] ++
        if(within_grace, do: [ip_matched: to_string(Keyword.fetch!(opts, :ip_matched))], else: [])

    Logger.warning(
      if(within_grace, do: "oauth_refresh_grace_reissue", else: "oauth_refresh_reuse"),
      Metadata.with_category(:warning, :lifecycle, metadata)
    )
  end

  @typedoc """
  Why a grant was refused. The wire response is always `invalid_grant` (RFC
  6749 §5.2 says nothing about which part was bad); the reason is for our logs
  and the `engram_prom_ex_oauth_token_total` `reason` label, so it is a closed
  set. Add a value here before returning it.
  """
  @type grant_reason ::
          :code_missing
          | :code_unknown
          | :code_consumed
          | :code_expired
          | :client_mismatch
          | :redirect_uri_mismatch
          | :pkce_verifier_missing
          | :pkce_mismatch
          | :user_not_found
          | :refresh_token_unknown
          | :refresh_token_revoked
          | :refresh_token_reuse
          | :refresh_token_expired

  # Analytics attribution for a refused grant (#1974): the code or refresh
  # token often resolved to a user before it was refused. Kept in the request
  # process rather than widened into the error tuple, because only the token
  # controller's analytics reads it; `take_grant_user_id/0` clears it.
  @grant_user_key :engram_oauth_grant_user_id

  defp put_grant_user_id(user_id), do: Process.put(@grant_user_key, user_id)

  defp put_code_user_id({:ok, %AuthorizationCode{user_id: user_id}}),
    do: put_grant_user_id(user_id)

  defp put_code_user_id(_), do: :ok

  @doc """
  The user the last grant attempt in this process resolved to, if any, and
  forgets it. For attributing `mcp_oauth_token_failed`.
  """
  @spec take_grant_user_id() :: String.t() | nil
  def take_grant_user_id, do: Process.delete(@grant_user_key)

  @spec grant_error(grant_reason()) :: {:error, {:invalid_grant, grant_reason()}}
  defp grant_error(reason), do: {:error, {:invalid_grant, reason}}

  defp find_unconsumed_code(nil), do: grant_error(:code_missing)

  defp find_unconsumed_code(raw_code) do
    case get_authorization_code_by_raw(raw_code) |> tap(&put_code_user_id/1) do
      {:ok, %AuthorizationCode{consumed_at: nil} = code} ->
        if DateTime.compare(DateTime.utc_now(), code.expires_at) == :gt,
          do: grant_error(:code_expired),
          else: {:ok, code}

      {:ok, %AuthorizationCode{}} ->
        grant_error(:code_consumed)

      _ ->
        grant_error(:code_unknown)
    end
  end

  # A CIMD client presents its document URL here while the code row stores the
  # internal UUID, so a literal mismatch is not yet a failure.
  #
  # `internal_client_id/2` already carries the equality short-circuit — passing
  # `actual` as the known value returns it without a query when the two match —
  # so the separate fast-path clause this used to have was a second copy of that
  # same check.
  defp check_code_client(%{client_id: actual}, requested) do
    if actual == internal_client_id(requested, actual),
      do: :ok,
      else: grant_error(:client_mismatch)
  end

  defp check_code_redirect_uri(%{redirect_uri: actual}, requested) when actual == requested,
    do: :ok

  defp check_code_redirect_uri(_, _), do: grant_error(:redirect_uri_mismatch)

  defp check_pkce_verifier(_code, nil), do: grant_error(:pkce_verifier_missing)

  defp check_pkce_verifier(%{code_challenge: challenge}, verifier) when is_binary(verifier) do
    derived = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(derived, challenge),
      do: :ok,
      else: grant_error(:pkce_mismatch)
  end

  defp check_pkce_verifier(_, _), do: grant_error(:pkce_mismatch)

  # Single-use enforcement (OAuth 2.1 §4.1.3): the conditional UPDATE is the
  # sole guarantee against an authorization-code double-spend race. The
  # app-level consumed_at==nil check in find_unconsumed_code/1 is a TOCTOU and
  # cannot serialize concurrent exchanges; only `WHERE consumed_at IS NULL` in
  # the UPDATE can. A 0-row result means another request already consumed it.
  defp consume_code(%AuthorizationCode{id: id}) do
    from(ac in AuthorizationCode, where: ac.id == ^id and is_nil(ac.consumed_at))
    |> Repo.update_all([set: [consumed_at: DateTime.utc_now(:second)]], skip_tenant_check: true)
    |> case do
      {1, _} -> :ok
      {0, _} -> grant_error(:code_consumed)
    end
  end

  defp fetch_user(user_id) do
    case Accounts.get_user(user_id) do
      %Accounts.User{} = user -> {:ok, user}
      _ -> grant_error(:user_not_found)
    end
  end

  # The columns a grant carries from its authorization code into its first
  # refresh token, and from each refresh token into its successor. Both source
  # structs expose all seven.
  #
  # Every one of them is immutable for the life of the family, because a
  # successor is the SAME grant: the user named it once (`label`), and it was
  # delivered to one redirect once (`redirect_uri`) — already matched against
  # the client's registered list at /authorize, and carried here so the
  # connections list can report where the code actually went rather than where
  # the client declared it could go (see #1204).
  @grant_fields ~w(client_id user_id vault_id vault_ids label scope redirect_uri)a

  defp grant_attrs(src, family_id, ip) do
    src
    |> Map.take(@grant_fields)
    |> Map.merge(%{family_id: family_id, last_used_at: DateTime.utc_now(), last_used_ip: ip})
  end

  defp insert_refresh_token(attrs) do
    raw = mint_token(@refresh_token_prefix)

    attrs =
      Map.merge(attrs, %{
        token_hash: hash_code(raw),
        expires_at: expires_in(@refresh_token_ttl_days * 24 * 3600)
      })

    case %RefreshToken{}
         |> RefreshToken.changeset(attrs)
         |> Repo.insert(skip_tenant_check: true) do
      {:ok, row} -> {:ok, raw, row}
      {:error, _} = err -> err
    end
  end

  # Reads the grant's effective vault scope, tolerating rows written before
  # the vault_ids column existed (scalar set, array NULL).
  defp grant_vault_ids(%{vault_ids: ids}) when is_list(ids) and ids != [], do: ids
  defp grant_vault_ids(%{vault_id: id}) when is_binary(id), do: [id]
  defp grant_vault_ids(_), do: nil

  defp issue_access_token(user, scope, vault_ids) do
    extras =
      %{}
      |> maybe_put("scope", scope)
      |> maybe_put("vault_ids", vault_ids)
      # Every restricted grant also emits the legacy scalar claim, carrying the
      # same first-of-set id the scalar column stores. A rolled-back reader
      # knows only `vault_id`, and a missing one reads as unrestricted — so
      # omitting it on a multi-vault grant would WIDEN the token to every
      # vault. Current readers check `vault_ids` first, so this is inert here.
      |> maybe_put("vault_id", scalar_vault_id(vault_ids))

    Accounts.generate_jwt(user, extras)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Dual-write for the expand phase. The legacy scalar column exists so a
  # rollback to the previous release NARROWS a grant instead of widening it:
  # old code reads only this column, and NULL there means "all vaults". A
  # multi-vault grant leaving it NULL would hand a rolled-back reader every
  # vault the user owns, including the ones they explicitly declined on the
  # consent screen — a privilege escalation caused by an ops action.
  #
  # So a multi-vault grant writes its FIRST id. `resolve_vaults/2` sorts, so
  # "first" is the lowest-sorted id, not an arbitrary one. The trade is
  # deliberate: after a rollback the user's integration loses the grant's other
  # vaults until roll-forward. Degraded beats escalated — a permission boundary
  # fails closed. `:all` (nil) stays NULL; unrestricted is what it already means.
  defp scalar_vault_id([first | _]), do: first
  defp scalar_vault_id(_), do: nil

  # ── Revocation (Phase 6) ─────────────────────────────────────────

  @doc """
  Revokes a refresh token if `client_id` matches the token's owner.
  Returns `:ok` always — leaks no info about token existence per
  RFC 7009 §2.2.
  """
  def revoke_token(nil, _client_id, _hint), do: :ok
  def revoke_token(_token, nil, _hint), do: :ok

  def revoke_token(raw_token, client_id, _hint) when is_binary(raw_token) do
    row = refresh_token_by_raw(raw_token)

    # Normalized against the row's own client_id so a CIMD client can revoke with
    # the URL it authenticates with. A nil (unknown wire id) matches nothing,
    # which lands on the catch-all below and still returns :ok per RFC 7009 §2.2.
    owner = internal_client_id(client_id, row && row.client_id)

    case row do
      %RefreshToken{client_id: ^owner, user_id: user_id} = rt ->
        _ =
          revoke_refresh_tokens(from(r in RefreshToken, where: r.id == ^rt.id),
            skip_tenant_check: true
          )

        # The matching access JWT lives outside our DB (Joken-signed, stateless)
        # and remains technically valid until exp. Force-disconnect live sockets
        # so any session still riding that access token loses its push channel
        # immediately rather than at exp.
        Engram.Auth.SessionInvalidator.disconnect_user(user_id)
        :ok

      _ ->
        :ok
    end
  end

  def revoke_token(_, _, _), do: :ok

  @doc """
  Drops expired authorization codes and revoked refresh tokens past a
  7-day grace window. Returns `{count_deleted, nil}`. Called by the
  hourly Engram.Workers.CleanupDeviceAuthWorker job alongside DeviceFlow
  cleanup so OAuth state doesn't leak.
  """
  def cleanup_expired do
    code_cutoff = DateTime.utc_now(:second) |> DateTime.add(-3600, :second)
    revoked_cutoff = DateTime.utc_now(:second) |> DateTime.add(-7 * 24 * 3600, :second)

    {codes, _} =
      from(ac in AuthorizationCode, where: ac.expires_at < ^code_cutoff)
      |> Repo.delete_all(skip_tenant_check: true)

    {revoked_tokens, _} =
      from(rt in RefreshToken,
        where: not is_nil(rt.revoked_at) and rt.revoked_at < ^revoked_cutoff
      )
      |> Repo.delete_all(skip_tenant_check: true)

    {expired_tokens, _} =
      from(rt in RefreshToken, where: rt.expires_at < ^revoked_cutoff)
      |> Repo.delete_all(skip_tenant_check: true)

    {codes + revoked_tokens + expired_tokens, nil}
  end

  # `grant` is the authorization code on the code grant and the just-consumed
  # refresh token on the refresh grant. Both answer `.scope`, `.vault_id` and
  # `.vault_ids`, which is the whole read — so ONE function serves both, and a
  # response field added later cannot land on one grant type and miss the other.
  defp build_token_response(user, grant, refresh_raw, _refresh_row) do
    %{
      access_token: issue_access_token(user, grant.scope, grant_vault_ids(grant)),
      refresh_token: refresh_raw,
      token_type: "Bearer",
      expires_in: Engram.Token.ttl_seconds(),
      scope: grant.scope
    }
  end

  # ── Internal ─────────────────────────────────────────────────────

  defp fetch_client(nil) do
    log_client_rejection(nil, :client_id_missing)
    {:client_error, "invalid_client"}
  end

  # The ONE place that may fetch a CIMD document. A URL-shaped client_id goes to
  # `Cimd.ensure_client/1`, which handles both first contact and TTL refresh.
  # Refreshing here rather than in `get_client/1` keeps network I/O on the
  # interactive authorize path only, never on token exchange or revocation.
  defp fetch_client(client_id) do
    if Cimd.url_shaped?(client_id) do
      case Cimd.ensure_client(client_id) do
        {:ok, client} -> {:ok, client}
        {:error, reason} -> cimd_error(reason)
      end
    else
      case get_client(client_id) do
        {:ok, client} ->
          {:ok, client}

        # The URL-shaped case never lands here — `Cimd.ensure_client/1` logs
        # its own `mcp_cimd_rejected`. This is a DCR id we have never issued.
        {:error, :not_found} ->
          log_client_rejection(client_id, :client_unknown)
          {:client_error, "invalid_client"}
      end
    end
  end

  # "We could not resolve this client" is not "this client does not exist".
  #
  # `invalid_client` is terminal: the client stops retrying and the user sees a
  # permanently dead connector. But our own fetch rate limiter, a vendor's 5xx,
  # a transport blip and a lost insert race are all OUR side of the wire and all
  # clear on their own. Reporting them as the vendor's fault is both wrong and
  # self-concealing — `:rate_limited` is deliberately never logged (see
  # `Engram.OAuth.Cimd`), so before this split a user in a retry loop produced a
  # stream of `invalid_client` pages and not one line of evidence.
  #
  # Explicit shapes, not `Cimd.transient_fetch_error?/1`: that predicate
  # defaults unknown reasons to transient, and this function also sees
  # document-validation refusals (a bad `client_id` binding), which are terminal.
  # Every transient shape `Cimd.HttpFetcher` can return is listed (#1974 review).
  defp cimd_error(reason)
       when reason in [
              :rate_limited,
              :fetch_failed,
              :store_conflict,
              :dns_failure,
              :budget_exhausted
            ],
       do: {:server_error, "temporarily_unavailable"}

  defp cimd_error({:transport_error, _phase, _reason}),
    do: {:server_error, "temporarily_unavailable"}

  defp cimd_error({:http_status, status}) when status >= 500 or status == 429,
    do: {:server_error, "temporarily_unavailable"}

  # A 4xx on the document URL is the vendor's to fix, as is a malformed or
  # unbindable document. Those are genuinely terminal for this client_id.
  defp cimd_error(_reason), do: {:client_error, "invalid_client"}

  defp match_redirect_uri(_client, nil), do: {:client_error, "invalid_redirect_uri"}

  defp match_redirect_uri(client, uri) do
    if uri in client.redirect_uris or loopback_port_match?(client.redirect_uris, uri) do
      {:ok, uri}
    else
      {:client_error, "invalid_redirect_uri"}
    end
  end

  # RFC 8252 §7.3: "the authorization server MUST allow any port to be specified
  # at the time of the request for loopback IP redirect URIs, to accommodate
  # clients that obtain an available ephemeral port from the operating system at
  # the time of the request."
  #
  # Exact matching is correct everywhere else and stays the first check above.
  # But a DCR client registers once and persists its client_id, while asking the
  # OS for a fresh ephemeral port on every launch. Without this, every
  # local-first connector (Claude Code, Cline, OpenCode, Cursor, Windsurf) works
  # on first run and fails on the second with invalid_redirect_uri.
  #
  # The exemption is scoped to `http` + a loopback host, and covers ONLY the
  # port: host, path and query must still match exactly. Extending it to https
  # would let anyone who controls any port on a registered host collect auth
  # codes. On loopback that concern does not apply the same way, since reaching
  # the port at all means already being on the user's machine, and PKCE still
  # binds the code to the request that started it.
  defp loopback_port_match?(registered, uri) do
    case loopback_identity(uri) do
      nil -> false
      identity -> Enum.any?(registered, &(loopback_identity(&1) == identity))
    end
  end

  # Everything identifying a loopback redirect except its port, or nil when the
  # URI is not an http loopback one (which disables the exemption entirely).
  #
  # The whole parsed URI is compared with the port blanked, rather than a
  # hand-listed subset of fields: that keeps userinfo and fragment significant
  # (`http://evil@127.0.0.1/cb` must not match `http://127.0.0.1/cb`) and cannot
  # silently widen if URI ever grows a field.
  defp loopback_identity(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: "http", host: host} = parsed} ->
        if Client.loopback_host?(host), do: %{parsed | port: nil}

      _ ->
        nil
    end
  end

  defp check_response_type(%{"response_type" => "code"}, _), do: :ok

  defp check_response_type(params, redirect_uri),
    do: {:redirect_error, redirect_uri, "unsupported_response_type", params["state"]}

  defp check_pkce(%{"code_challenge" => challenge} = params, redirect_uri)
       when is_binary(challenge) and challenge != "" do
    case params["code_challenge_method"] do
      m when m in [nil, "S256"] -> :ok
      _ -> {:redirect_error, redirect_uri, "invalid_request", params["state"]}
    end
  end

  defp check_pkce(params, redirect_uri),
    do: {:redirect_error, redirect_uri, "invalid_request", params["state"]}

  # RFC 6749 §3.3: the server may issue a narrower scope than requested, and
  # says so in the token response. Unknown scopes are dropped, never refused
  # (#1974): connectors add `offline_access`, `openid` or `profile` by habit,
  # and an `invalid_scope` redirect killed the connection with a message the
  # user never saw. `offline_access` is meaningful but needs no grant scope:
  # every grant gets a refresh token. Nothing requested that we know → `mcp`.
  #
  # Returns `{granted, requested}`; `requested` is only for analytics, capped so
  # a hostile scope string stays bounded.
  defp narrow_scope(scope) when is_binary(scope) do
    requested = scope |> String.split(" ", trim: true) |> Enum.take(@max_requested_scopes)

    granted =
      case Enum.filter(requested, &(&1 in @valid_scopes)) do
        [] -> "mcp"
        known -> known |> Enum.uniq() |> Enum.join(" ")
      end

    {granted, requested}
  end

  defp narrow_scope(_scope), do: {"mcp", []}

  # Resolves a vault selection to the id list stored on the grant.
  #
  # `:all` → {:ok, nil} — NULL keeps its existing meaning, including vaults
  # created after the grant. An explicit list is verified in ONE query; if
  # any id is unowned, deleted, or unknown, the WHOLE grant fails. Partially
  # honouring a selection would silently hand out a scope the user never
  # confirmed on the consent screen.
  defp resolve_vaults(_user, :all), do: {:ok, nil}

  defp resolve_vaults(_user, []), do: :error

  defp resolve_vaults(user, ids) when is_list(ids) do
    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    if Enum.any?(casted, &(&1 == :error)) do
      :error
    else
      wanted = casted |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()

      query =
        from(v in Engram.Vaults.Vault,
          where: v.id in ^wanted and v.user_id == ^user.id and is_nil(v.deleted_at),
          select: v.id
        )

      # `vaults` carries FORCE ROW LEVEL SECURITY, so unscoped this returned
      # `[]`, the length comparison failed, and EVERY selection was rejected as
      # `:error` — which `mint_authorization_code/4` turns into an
      # `access_denied` redirect. A user granting a client access to a vault
      # they own was refused, and the refusal named the wrong cause.
      #
      # The ownership predicate above is still the right check and stays; it
      # simply never got the chance to be correct, because the policy filters
      # first. Only this multi-vault branch was affected — `:all`
      # short-circuits above without a query, which is why the existing OAuth
      # tests (almost all `:all`) never caught it.
      case Repo.with_tenant!(user.id, fn -> Repo.all(query) end) do
        found when length(found) == length(wanted) -> {:ok, Enum.sort(found)}
        _ -> :error
      end
    end
  end

  defp resolve_vaults(_user, _), do: :error

  # A label is free text the user typed on the consent screen, rendered back to
  # them in the connections list. Bound the length rather than truncating —
  # silently storing something other than what they typed is worse than
  # refusing. Blank (or whitespace-only) is not a choice, it is the untouched
  # default, and stores NULL so the client identity keeps showing through.
  @max_label_chars 120

  # A grapheme bound is NOT a size bound: one grapheme cluster can carry
  # arbitrarily many combining marks, so 120 graphemes can be megabytes. The
  # column is `:text` and the value is re-copied into a new row on every
  # rotation, so the only other ceiling is Plug.Parsers' 11MB body limit.
  #
  # 4096, not 4 bytes/grapheme: measured worst-case REAL graphemes are far
  # wider than 4 bytes — a tag-sequence flag (🏴󠁧󠁢󠁥󠁮󠁧󠁿) is 28 bytes and a 4-person
  # ZWJ family is 25, so 120 of them is 3360/3000 bytes. A 480-byte cap would
  # reject a legitimate all-emoji label. 4096 clears every real sequence while
  # still refusing the combining-mark stack class (120 such graphemes measured
  # at 48120 bytes).
  @max_label_bytes 4096

  @doc """
  Validates a user-typed connection label: trimmed, blank becomes `nil`, and an
  over-long value is `:error` rather than truncated. Shared with the device
  flow so both link surfaces enforce the same bound.
  """
  @spec resolve_label(term()) :: {:ok, String.t() | nil} | :error
  def resolve_label(nil), do: {:ok, nil}

  def resolve_label(label) when is_binary(label) do
    trimmed = String.trim(label)

    cond do
      trimmed == "" -> {:ok, nil}
      byte_size(trimmed) > @max_label_bytes -> :error
      String.length(trimmed) > @max_label_chars -> :error
      true -> {:ok, trimmed}
    end
  end

  def resolve_label(_), do: :error

  @doc """
  Appends `params` to a redirect URI: drops nil/blank pairs, then picks `&` or
  `?` depending on whether the base already carries a query string.

  Public for `EngramWeb.OAuthAuthorizeController`, which had rebuilt the same
  three steps as its own `build_error_url/3`. The split was by accident of
  ownership, not design — SUCCESS redirects (`code` + `state`) are minted in
  this module and ERROR redirects in the controller — so the two copies of the
  separator rule could only drift apart.
  """
  @spec build_redirect(String.t(), map()) :: String.t()
  def build_redirect(base, params) do
    cleaned = params |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()
    sep = if String.contains?(base, "?"), do: "&", else: "?"
    base <> sep <> URI.encode_query(cleaned)
  end

  # The three prefixed random tokens this module mints — client secret,
  # authorization code, refresh token — differed only in their prefix.
  #
  # Deliberately NOT shared with `Engram.Accounts`, `Engram.Invites` or
  # `Engram.Auth.DeviceFlow`, which mint their own: a cross-module minter would
  # be a new abstraction rather than a deletion.
  defp mint_token(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  defp expires_in(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp hash_code(raw), do: Engram.Crypto.sha256_hex(raw)
end
