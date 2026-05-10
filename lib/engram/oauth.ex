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
  alias Engram.OAuth.{AuthorizationCode, Client}
  alias Engram.Repo

  @code_bytes 32
  @code_ttl_seconds 600
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
    case Integer.parse(id_str) do
      {id, ""} -> verify_vault_ownership(user, id)
      _ -> :error
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
