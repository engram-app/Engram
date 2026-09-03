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
  alias Engram.OAuth.{AuthorizationCode, Cimd, Client, RefreshToken}
  alias Engram.Repo

  @code_bytes 32
  @code_ttl_seconds 600
  @max_state_bytes 2048
  @refresh_token_prefix "engram_oauth_rt_"
  @refresh_token_bytes 32
  @refresh_token_ttl_days 90
  @valid_scopes ~w(mcp)

  # ── Clients (Phase 2) ────────────────────────────────────────────

  @client_secret_prefix "engram_oauth_cs_"
  @client_secret_bytes 32

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
    if Client.confidential?(method) do
      @client_secret_prefix <>
        Base.url_encode64(:crypto.strong_rand_bytes(@client_secret_bytes), padding: false)
    end
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
          :ok | {:error, :invalid_client}
  def authenticate_client(client_id, secret) do
    case get_client(client_id) do
      {:ok, client} -> check_client_secret(client, secret)
      # Unknown client_id is indistinguishable from a bad secret on purpose.
      {:error, :not_found} -> {:error, :invalid_client}
    end
  end

  defp check_client_secret(client, secret) do
    cond do
      not Client.confidential?(client.token_endpoint_auth_method) ->
        if is_nil(secret), do: :ok, else: {:error, :invalid_client}

      is_nil(secret) or is_nil(client.client_secret_hash) ->
        {:error, :invalid_client}

      Plug.Crypto.secure_compare(hash_code(secret), client.client_secret_hash) ->
        :ok

      true ->
        {:error, :invalid_client}
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
         :ok <- check_state_length(params),
         :ok <- check_scope(params, redirect_uri) do
      {:ok,
       %{
         client: client,
         client_id: client.client_id,
         client_name: client.client_name,
         redirect_uri: redirect_uri,
         code_challenge: params["code_challenge"],
         code_challenge_method: params["code_challenge_method"] || "S256",
         scope: params["scope"] || "mcp",
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
      raw_code =
        "engram_ac_" <>
          Base.url_encode64(:crypto.strong_rand_bytes(@code_bytes), padding: false)

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@code_ttl_seconds, :second)
        |> DateTime.truncate(:second)

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
        expires_at: expires_at
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
           insert_refresh_token(%{
             family_id: Ecto.UUID.generate(),
             client_id: code_row.client_id,
             user_id: code_row.user_id,
             vault_id: code_row.vault_id,
             vault_ids: code_row.vault_ids,
             label: code_row.label,
             scope: code_row.scope,
             # Where the code was actually delivered — already matched against
             # the client's registered list at /authorize. Carried onto the
             # grant so the connections list can verify what happened rather
             # than what the client declared possible. See #1204.
             redirect_uri: code_row.redirect_uri,
             last_used_at: DateTime.utc_now(),
             last_used_ip: ip
           }) do
      {:ok, build_token_response(user, code_row, refresh_raw, refresh_row)}
    end
  end

  @doc """
  Rotates a refresh token: marks the presented one consumed, mints + issues
  a successor in the same family. If the presented token is already
  consumed (replay) or revoked, this revokes the entire family per
  RFC 6749 §10.4.
  """
  def rotate_refresh_token(raw_token, client_id, opts \\ []) do
    ip = Keyword.get(opts, :ip)
    hash = hash_code(raw_token)

    case Repo.one(from(rt in RefreshToken, where: rt.token_hash == ^hash),
           skip_tenant_check: true
         ) do
      nil ->
        {:error, :invalid_grant}

      %RefreshToken{} = rt ->
        rotate_existing(rt, internal_client_id(client_id, rt.client_id), ip)
    end
  end

  defp rotate_existing(%RefreshToken{client_id: actual}, requested, _ip) when actual != requested,
    do: {:error, :invalid_grant}

  defp rotate_existing(%RefreshToken{revoked_at: %DateTime{}} = rt, _client_id, _ip) do
    revoke_family(rt.family_id)
    {:error, :invalid_grant}
  end

  defp rotate_existing(%RefreshToken{consumed_at: %DateTime{}} = rt, _client_id, _ip) do
    revoke_family(rt.family_id)
    {:error, :invalid_grant}
  end

  defp rotate_existing(%RefreshToken{expires_at: exp} = rt, _client_id, ip) do
    if DateTime.compare(DateTime.utc_now(), exp) == :gt do
      {:error, :invalid_grant}
    else
      do_rotate(rt, ip)
    end
  end

  defp do_rotate(rt, ip) do
    now = DateTime.utc_now(:second)

    # Atomic compare-and-set: only one concurrent rotation may consume this
    # token. A 0-row result means another request already rotated it — that is
    # a replay of a now-consumed token, so revoke the whole family
    # (RFC 6749 §10.4) and reject, mirroring rotate_existing/3's replay branch.
    case from(r in RefreshToken, where: r.id == ^rt.id and is_nil(r.consumed_at))
         |> Repo.update_all([set: [consumed_at: now]], skip_tenant_check: true) do
      {0, _} ->
        revoke_family(rt.family_id)
        {:error, :invalid_grant}

      {1, _} ->
        mint_rotation_successor(rt, ip)
    end
  end

  defp mint_rotation_successor(rt, ip) do
    {:ok, refresh_raw, refresh_row} =
      insert_refresh_token(%{
        family_id: rt.family_id,
        client_id: rt.client_id,
        user_id: rt.user_id,
        vault_id: rt.vault_id,
        vault_ids: rt.vault_ids,
        # Immutable for the life of the family, like redirect_uri below: a
        # successor is the SAME grant, and the user named it once.
        label: rt.label,
        scope: rt.scope,
        # Immutable for the life of the family, like family_id: rotation mints
        # a successor to the SAME grant, and the grant was delivered once.
        redirect_uri: rt.redirect_uri,
        last_used_at: DateTime.utc_now(),
        last_used_ip: ip
      })

    case fetch_user(rt.user_id) do
      {:ok, user} ->
        {:ok,
         %{
           access_token: issue_access_token(user, rt.scope, grant_vault_ids(rt)),
           refresh_token: refresh_raw,
           token_type: "Bearer",
           expires_in: Engram.Token.ttl_seconds(),
           scope: rt.scope
         }}

      err ->
        # Roll back the new refresh row if user lookup failed (shouldn't
        # happen — user_id FK guarantees existence — but keep tidy).
        Repo.delete!(refresh_row, skip_tenant_check: true)
        err
    end
  end

  defp revoke_family(family_id) do
    now = DateTime.utc_now(:second)

    from(rt in RefreshToken,
      where: rt.family_id == ^family_id and is_nil(rt.revoked_at)
    )
    |> Repo.update_all([set: [revoked_at: now]], skip_tenant_check: true)
  end

  defp find_unconsumed_code(nil), do: {:error, :invalid_grant}

  defp find_unconsumed_code(raw_code) do
    case get_authorization_code_by_raw(raw_code) do
      {:ok, %AuthorizationCode{consumed_at: nil} = code} ->
        if DateTime.compare(DateTime.utc_now(), code.expires_at) == :gt,
          do: {:error, :invalid_grant},
          else: {:ok, code}

      _ ->
        {:error, :invalid_grant}
    end
  end

  defp check_code_client(%{client_id: actual}, requested) when actual == requested, do: :ok

  # A CIMD client presents its document URL here while the code row stores the
  # internal UUID, so a literal mismatch is not yet a failure. Only reached when
  # the fast path above misses, which is either that case or a genuinely wrong
  # client.
  defp check_code_client(%{client_id: actual}, requested) do
    if actual == internal_client_id(requested), do: :ok, else: {:error, :invalid_grant}
  end

  defp check_code_redirect_uri(%{redirect_uri: actual}, requested) when actual == requested,
    do: :ok

  defp check_code_redirect_uri(_, _), do: {:error, :invalid_grant}

  defp check_pkce_verifier(_code, nil), do: {:error, :invalid_grant}

  defp check_pkce_verifier(%{code_challenge: challenge}, verifier) when is_binary(verifier) do
    derived = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(derived, challenge),
      do: :ok,
      else: {:error, :invalid_grant}
  end

  defp check_pkce_verifier(_, _), do: {:error, :invalid_grant}

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
      {0, _} -> {:error, :invalid_grant}
    end
  end

  defp fetch_user(user_id) do
    case Accounts.get_user(user_id) do
      %Accounts.User{} = user -> {:ok, user}
      _ -> {:error, :invalid_grant}
    end
  end

  defp insert_refresh_token(attrs) do
    raw =
      @refresh_token_prefix <>
        Base.url_encode64(:crypto.strong_rand_bytes(@refresh_token_bytes), padding: false)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@refresh_token_ttl_days * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    case %RefreshToken{}
         |> RefreshToken.changeset(
           Map.put(attrs, :token_hash, hash_code(raw))
           |> Map.put(:expires_at, expires_at)
         )
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
      # Single-vault grants keep emitting the legacy scalar claim so a token
      # minted here stays readable by a rolled-back release. Multi-vault
      # grants omit it — there is no scalar that means "A and C", and the old
      # reader treats a missing claim as unrestricted, so it must never see
      # one it would misread as narrower than it is.
      |> then(fn m ->
        case vault_ids do
          [only] -> Map.put(m, "vault_id", only)
          _ -> m
        end
      end)

    Accounts.generate_jwt(user, extras)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Dual-write for the expand phase: a single-vault grant also populates the
  # legacy scalar column so a rollback to the previous release still reads a
  # correct binding. Multi-vault grants leave it NULL — there is no correct
  # scalar answer, and NULL there means "all vaults" to old code, which is
  # why multi-vault grants must not be rolled back into.
  defp scalar_vault_id([only]), do: only
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
    hash = hash_code(raw_token)

    row =
      Repo.one(from(rt in RefreshToken, where: rt.token_hash == ^hash), skip_tenant_check: true)

    # Normalized against the row's own client_id so a CIMD client can revoke with
    # the URL it authenticates with. A nil (unknown wire id) matches nothing,
    # which lands on the catch-all below and still returns :ok per RFC 7009 §2.2.
    owner = internal_client_id(client_id, row && row.client_id)

    case row do
      %RefreshToken{client_id: ^owner, user_id: user_id} = rt ->
        rt
        |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now(:second)})
        |> Repo.update!(skip_tenant_check: true)

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

  defp build_token_response(user, code_row, refresh_raw, _refresh_row) do
    %{
      access_token: issue_access_token(user, code_row.scope, grant_vault_ids(code_row)),
      refresh_token: refresh_raw,
      token_type: "Bearer",
      expires_in: Engram.Token.ttl_seconds(),
      scope: code_row.scope
    }
  end

  # ── Internal ─────────────────────────────────────────────────────

  defp fetch_client(nil), do: {:client_error, "invalid_client"}

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
        {:ok, client} -> {:ok, client}
        {:error, :not_found} -> {:client_error, "invalid_client"}
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
  defp cimd_error(reason)
       when reason in [:rate_limited, :fetch_failed, :store_conflict],
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

  defp check_scope(%{"scope" => nil}, _), do: :ok
  defp check_scope(%{"scope" => ""}, _), do: :ok

  defp check_scope(%{"scope" => scope} = params, redirect_uri) when is_binary(scope) do
    requested = String.split(scope, " ", trim: true)

    if Enum.all?(requested, &(&1 in @valid_scopes)) do
      :ok
    else
      {:redirect_error, redirect_uri, "invalid_scope", params["state"]}
    end
  end

  defp check_scope(_params, _redirect_uri), do: :ok

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

      case Repo.all(query, skip_tenant_check: true) do
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

  defp resolve_label(nil), do: {:ok, nil}

  defp resolve_label(label) when is_binary(label) do
    trimmed = String.trim(label)

    cond do
      trimmed == "" -> {:ok, nil}
      byte_size(trimmed) > @max_label_bytes -> :error
      String.length(trimmed) > @max_label_chars -> :error
      true -> {:ok, trimmed}
    end
  end

  defp resolve_label(_), do: :error

  defp build_redirect(base, params) do
    cleaned = params |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()
    sep = if String.contains?(base, "?"), do: "&", else: "?"
    base <> sep <> URI.encode_query(cleaned)
  end

  defp hash_code(raw), do: Engram.Crypto.sha256_hex(raw)
end
