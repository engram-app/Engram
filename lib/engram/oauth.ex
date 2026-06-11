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
  alias Engram.OAuth.{AuthorizationCode, Client, RefreshToken}
  alias Engram.Repo

  @code_bytes 32
  @code_ttl_seconds 600
  @refresh_token_prefix "engram_oauth_rt_"
  @refresh_token_bytes 32
  @refresh_token_ttl_days 90
  @valid_scopes ~w(mcp)

  # ── Clients (Phase 2) ────────────────────────────────────────────

  def register_client(attrs) do
    %Client{}
    |> Client.registration_changeset(attrs)
    |> Repo.insert(skip_tenant_check: true)
  end

  def get_client(client_id) when is_binary(client_id) do
    case Ecto.UUID.cast(client_id) do
      {:ok, _} ->
        case Repo.one(from(c in Client, where: c.client_id == ^client_id),
               skip_tenant_check: true
             ) do
          nil -> {:error, :not_found}
          client -> {:ok, client}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_client(_), do: {:error, :not_found}

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
  """
  def validate_authorization_request(params) when is_map(params) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, redirect_uri} <- match_redirect_uri(client, params["redirect_uri"]),
         :ok <- check_response_type(params, redirect_uri),
         :ok <- check_pkce(params, redirect_uri),
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

  @doc """
  Mints an authorization code for a validated request + a vault selection.

  `vault_choice` is `"vault:<id>"` or `"vault:*"`. Vault ownership is
  verified — a user cannot grant an OAuth client access to a vault they
  do not own.

  Returns `{:ok, redirect_url}` (caller 302s) or
  `{:redirect_error, redirect_uri, error_code, state}`.
  """
  def mint_authorization_code(user, validated, vault_choice) do
    case resolve_vault(user, vault_choice) do
      {:ok, vault_id} ->
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
          vault_id: vault_id,
          state: validated.state,
          expires_at: expires_at
        }

        case %AuthorizationCode{}
             |> AuthorizationCode.changeset(attrs)
             |> Repo.insert(skip_tenant_check: true) do
          {:ok, _row} ->
            {:ok,
             build_redirect(validated.redirect_uri, %{code: raw_code, state: validated.state})}

          {:error, changeset} ->
            {:error, changeset}
        end

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
             scope: code_row.scope,
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
        rotate_existing(rt, client_id, ip)
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

    rt
    |> Ecto.Changeset.change(%{consumed_at: now})
    |> Repo.update!(skip_tenant_check: true)

    {:ok, refresh_raw, refresh_row} =
      insert_refresh_token(%{
        family_id: rt.family_id,
        client_id: rt.client_id,
        user_id: rt.user_id,
        vault_id: rt.vault_id,
        scope: rt.scope,
        last_used_at: DateTime.utc_now(),
        last_used_ip: ip
      })

    case fetch_user(rt.user_id) do
      {:ok, user} ->
        {:ok,
         %{
           access_token: issue_access_token(user, rt.scope, rt.vault_id),
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
  defp check_code_client(_, _), do: {:error, :invalid_grant}

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

  defp consume_code(%AuthorizationCode{} = code) do
    code
    |> Ecto.Changeset.change(%{
      consumed_at: DateTime.utc_now(:second)
    })
    |> Repo.update(skip_tenant_check: true)
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :server_error}
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

  defp issue_access_token(user, scope, vault_id) do
    extras =
      %{}
      |> maybe_put("scope", scope)
      |> maybe_put("vault_id", vault_id)

    Accounts.generate_jwt(user, extras)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

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

    case Repo.one(from(rt in RefreshToken, where: rt.token_hash == ^hash),
           skip_tenant_check: true
         ) do
      %RefreshToken{client_id: ^client_id, user_id: user_id} = rt ->
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
      access_token: issue_access_token(user, code_row.scope, code_row.vault_id),
      refresh_token: refresh_raw,
      token_type: "Bearer",
      expires_in: Engram.Token.ttl_seconds(),
      scope: code_row.scope
    }
  end

  # ── Internal ─────────────────────────────────────────────────────

  defp fetch_client(nil), do: {:client_error, "invalid_client"}

  defp fetch_client(client_id) do
    case get_client(client_id) do
      {:ok, client} -> {:ok, client}
      {:error, :not_found} -> {:client_error, "invalid_client"}
    end
  end

  defp match_redirect_uri(_client, nil), do: {:client_error, "invalid_redirect_uri"}

  defp match_redirect_uri(client, uri) do
    if uri in client.redirect_uris do
      {:ok, uri}
    else
      {:client_error, "invalid_redirect_uri"}
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

  defp resolve_vault(_user, "vault:*"), do: {:ok, nil}

  defp resolve_vault(user, "vault:" <> id_str) do
    case Ecto.UUID.cast(id_str) do
      {:ok, id} -> verify_vault_ownership(user, id)
      :error -> :error
    end
  end

  defp resolve_vault(_user, _), do: :error

  defp verify_vault_ownership(user, vault_id) do
    query =
      from(v in Engram.Vaults.Vault,
        where: v.id == ^vault_id and v.user_id == ^user.id and is_nil(v.deleted_at)
      )

    case Repo.one(query, skip_tenant_check: true) do
      nil -> :error
      _vault -> {:ok, vault_id}
    end
  end

  defp build_redirect(base, params) do
    cleaned = params |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()
    sep = if String.contains?(base, "?"), do: "&", else: "?"
    base <> sep <> URI.encode_query(cleaned)
  end

  defp hash_code(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
