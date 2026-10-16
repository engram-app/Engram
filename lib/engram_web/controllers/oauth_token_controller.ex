defmodule EngramWeb.OAuthTokenController do
  @moduledoc """
  RFC 6749 §3.2 token endpoint. Public client + PKCE today; mounted under
  `:oauth_api` (rate-limited per IP). Accepts both
  `application/x-www-form-urlencoded` and `application/json` bodies via the
  endpoint's standard parsers.
  """
  use EngramWeb, :controller

  import EngramWeb.OAuthClientAuth,
    only: [clear_request_state: 2, blank_to_nil: 1, maybe_challenge: 1]

  alias Engram.Accounts.User
  alias Engram.Analytics.McpClient
  alias Engram.OAuth
  alias Engram.OAuth.Cimd.JwksCache
  alias EngramWeb.OAuthClientAuth
  alias EngramWeb.OAuthMetadata
  alias EngramWeb.RemoteIp
  alias EngramWeb.RequestMeta

  plug :clear_request_state

  # RFC 6749 §5.1 / OAuth 2.1 §3.2.3: token responses MUST NOT be cached. Set on
  # errors too, so no intermediary ever stores anything from this endpoint.
  plug :no_store

  # RFC 8707 §2.2: a token request naming a resource other than this server is
  # refused before anything is spent, for either grant.
  def exchange(conn, %{"grant_type" => grant, "resource" => resource} = params)
      when grant in ["authorization_code", "refresh_token"] and
             (is_binary(resource) or is_list(resource)) do
    if OAuthMetadata.mcp_resource?(resource) do
      exchange(conn, Map.delete(params, "resource"))
    else
      grant_type = String.to_existing_atom(grant)
      reject(conn, grant_type, params["client_id"], "invalid_target", :resource_not_ours)
    end
  end

  def exchange(conn, %{"grant_type" => "authorization_code"} = params) do
    case OAuthClientAuth.authenticate(conn, params) do
      {:ok, client_id} ->
        ip = RequestMeta.format_ip(RemoteIp.resolve(conn))

        # Feed back the RESOLVED client_id: it may have arrived via HTTP Basic
        # rather than the body, and the grant check compares the code's client
        # against this param. Reading the body directly would fail every
        # Basic-authenticated exchange that omits the redundant body field.
        OAuth.exchange_authorization_code(Map.put(params, "client_id", client_id), ip: ip)
        |> grant_result(conn, :authorization_code, client_id)

      {:error, reason} ->
        auth_error(conn, :authorization_code, reason)
    end
  end

  def exchange(conn, %{"grant_type" => "refresh_token"} = params) do
    case OAuthClientAuth.authenticate(conn, params) do
      {:ok, client_id} ->
        case params["refresh_token"] do
          raw when is_binary(raw) and raw != "" ->
            ip = RequestMeta.format_ip(RemoteIp.resolve(conn))

            OAuth.rotate_refresh_token(raw, client_id, ip: ip)
            |> grant_result(conn, :refresh_token, client_id)

          _ ->
            reject(conn, :refresh_token, client_id, "invalid_request", :refresh_token_missing)
        end

      {:error, reason} ->
        auth_error(conn, :refresh_token, reason)
    end
  end

  def exchange(conn, %{"grant_type" => _other} = params),
    do:
      reject(conn, :other, params["client_id"], "unsupported_grant_type", :unsupported_grant_type)

  def exchange(conn, params),
    do: reject(conn, :missing, params["client_id"], "invalid_request", :grant_type_missing)

  # RFC 6749 §5.2: a bad grant is 400 `invalid_grant`, and says nothing about
  # WHICH part of the grant was bad. The reason goes to our log and metric only.
  #
  # The non-grant error is `insert_refresh_token/1`'s changeset. It was already
  # answered `invalid_grant`; that stays, under its own reason so it is visible.
  defp grant_result({:ok, response}, conn, grant_type, client_id) do
    emit(grant_type, :issued, nil, :none)
    track_issued(conn, grant_type, client_id, response)
    json(conn, response)
  end

  defp grant_result({:error, {:invalid_grant, reason}}, conn, grant_type, client_id),
    do: reject(conn, grant_type, client_id, "invalid_grant", reason)

  defp grant_result({:error, _changeset}, conn, grant_type, client_id),
    do: reject(conn, grant_type, client_id, "invalid_grant", :token_persist_failed)

  # Every 400 this endpoint returns goes through here, so each one leaves
  # exactly one `oauth_token_rejected` line and one telemetry event (#1974).
  # Before this the grant refusals were silent, and a connector whose refresh
  # kept failing showed nothing until the user re-authorized by hand.
  #
  # Nothing request-supplied is logged raw: `client_id` only when it is a UUID
  # (a CIMD URL id is reduced to its host by `log_refusal/4`), and the user
  # agent truncated as `EngramWeb.RequestLogger` does. Codes, verifiers and
  # tokens never reach this function.
  defp reject(conn, grant_type, client_id, error, reason) do
    OAuth.log_refusal("oauth_token_rejected", client_id, reason,
      error_code: error,
      grant_type: Atom.to_string(grant_type),
      client_id: uuid_or_nil(client_id),
      user_agent: RequestMeta.log_user_agent(conn)
    )

    emit(grant_type, :rejected, error, reason)
    track_failed(conn, grant_type, client_id, error, reason)

    conn
    |> put_status(:bad_request)
    |> json(%{error: error})
  end

  # One event for both outcomes, because the PromEx counter keys its telemetry
  # handler on the metric name: two events feeding one
  # `engram_prom_ex_oauth_token_total` would silently drop the second. All
  # three labels are closed atom sets; never add the client here.
  defp emit(grant_type, result, error, reason) do
    :telemetry.execute([:engram, :oauth, :token], %{count: 1}, %{
      grant_type: grant_type,
      result: result,
      error: error,
      reason: reason
    })
  end

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  # ── Product analytics (#1974) ──────────────────────────────────────
  #
  # The funnel events behind the telemetry above, through `Engram.Analytics`.
  # Every prop is a bounded label: never a code, verifier, token or raw id.

  defp track_issued(conn, grant_type, client_id, response) do
    props =
      client_id
      |> client_props()
      |> Map.merge(%{
        grant_type: Atom.to_string(grant_type),
        auth_method: auth_method(conn),
        jwks_source: jwks_source()
      })

    case issued_user(response) do
      nil -> Engram.Analytics.track_anonymous("mcp_oauth_token_issued", props)
      user -> Engram.Analytics.track(user, "mcp_oauth_token_issued", props)
    end
  end

  # The user is known whenever the code or refresh token resolved to a row
  # (`OAuth.take_grant_user_id/0`); otherwise the event is anonymous.
  defp track_failed(conn, grant_type, client_id, error, reason) do
    props =
      client_id
      |> client_props()
      |> Map.merge(%{
        grant_type: Atom.to_string(grant_type),
        auth_method: auth_method(conn),
        error: error,
        reason: Atom.to_string(reason)
      })

    case OAuth.take_grant_user_id() do
      nil -> Engram.Analytics.track_anonymous("mcp_oauth_token_failed", props)
      user_id -> Engram.Analytics.track(%User{id: user_id}, "mcp_oauth_token_failed", props)
    end
  end

  defp client_props(client_id) do
    client =
      case OAuth.get_client(client_id) do
        {:ok, client} -> client
        _ -> nil
      end

    McpClient.client_props(client)
  end

  # The access token we just minted names its user; reading our own claim
  # back is cheaper than threading the user out of `Engram.OAuth`.
  defp issued_user(%{access_token: token}) when is_binary(token) do
    case Joken.peek_claims(token) do
      {:ok, %{"user_id" => id}} when is_binary(id) -> %User{id: id}
      _ -> nil
    end
  end

  defp issued_user(_response), do: nil

  defp auth_method(conn) do
    cond do
      is_binary(blank_to_nil(conn.params["client_assertion"])) -> "private_key_jwt"
      Plug.BasicAuth.parse_basic_auth(conn) != :error -> "client_secret_basic"
      is_binary(blank_to_nil(conn.params["client_secret"])) -> "client_secret_post"
      true -> "none"
    end
  end

  defp jwks_source do
    case JwksCache.take_source() do
      nil -> "none"
      source -> Atom.to_string(source)
    end
  end

  # For the client-authentication failures, which never resolved a client id.
  defp request_client_id(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {id, _secret} -> id
      :error -> conn.params["client_id"]
    end
  end

  defp uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_or_nil(_id), do: nil

  # RFC 6749 §5.2: failed client authentication is 401, and a request that used
  # the Authorization header gets a WWW-Authenticate challenge back.
  defp invalid_client(conn, grant_type) do
    emit(grant_type, :rejected, "invalid_client", :client_auth_failed)
    track_failed(conn, grant_type, request_client_id(conn), "invalid_client", :client_auth_failed)

    conn
    |> maybe_challenge()
    |> put_status(:unauthorized)
    |> json(%{error: "invalid_client"})
  end

  # RFC 6749 §5.2 makes `invalid_client` TERMINAL — the connector stops retrying
  # and the user sees a permanently dead integration. Our own fetch throttle and
  # an unreachable vendor JWKS endpoint both clear on their own, so they must be
  # retryable. Same split `Engram.OAuth.cimd_error/1` already makes on the
  # authorize path, and the same string it uses.
  defp temporarily_unavailable(conn, grant_type) do
    emit(grant_type, :rejected, "temporarily_unavailable", :client_auth_unavailable)

    track_failed(
      conn,
      grant_type,
      request_client_id(conn),
      "temporarily_unavailable",
      :client_auth_unavailable
    )

    # A hint to retry soon (#1974): ChatGPT did not retry the 2026-10-13 503 at
    # all, and the condition behind it clears within seconds.
    conn
    |> put_resp_header("retry-after", "2")
    |> put_status(:service_unavailable)
    |> json(%{error: "temporarily_unavailable"})
  end

  # Both `exchange/2` clauses authenticate the client identically, so they fail
  # identically. Two clauses rather than a catch-all: a reason neither
  # `authenticate_client/3` nor `client_credentials/2` can return must crash
  # loudly instead of being reported as one of these two.
  #
  # These already log inside `Engram.OAuth` (`oauth_client_rejected` and
  # siblings, with the precise reason), so they only add the metric here.
  defp auth_error(conn, grant_type, :invalid_client), do: invalid_client(conn, grant_type)

  defp auth_error(conn, grant_type, :temporarily_unavailable),
    do: temporarily_unavailable(conn, grant_type)
end
