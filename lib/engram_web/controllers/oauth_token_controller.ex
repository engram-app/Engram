defmodule EngramWeb.OAuthTokenController do
  @moduledoc """
  RFC 6749 §3.2 token endpoint. Public client + PKCE today; mounted under
  `:oauth_api` (rate-limited per IP). Accepts both
  `application/x-www-form-urlencoded` and `application/json` bodies via the
  endpoint's standard parsers.
  """
  use EngramWeb, :controller

  alias Engram.Accounts.User
  alias Engram.Analytics.McpClient
  alias Engram.OAuth
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Cimd.JwksCache
  alias EngramWeb.OAuthMetadata
  alias EngramWeb.RemoteIp
  alias EngramWeb.RequestMeta

  # The JWKS source and the grant's user live in the request process (they are
  # set several frames below this controller). A keep-alive connection reuses
  # that process, so both are cleared before every request and again as the
  # response goes out, whatever the outcome (#1974 review #13).
  plug :clear_request_state

  def exchange(conn, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, client_id, secret, assertion} <- client_credentials(conn, params),
         :ok <- OAuth.authenticate_client(client_id, secret, auth_opts(conn, assertion)) do
      ip = RequestMeta.format_ip(RemoteIp.resolve(conn))

      # Feed back the RESOLVED client_id: it may have arrived via HTTP Basic
      # rather than the body, and the grant check compares the code's client
      # against this param. Reading the body directly would fail every
      # Basic-authenticated exchange that omits the redundant body field.
      OAuth.exchange_authorization_code(Map.put(params, "client_id", client_id), ip: ip)
      |> grant_result(conn, :authorization_code, client_id)
    else
      {:error, reason} -> auth_error(conn, :authorization_code, reason)
    end
  end

  def exchange(conn, %{"grant_type" => "refresh_token"} = params) do
    with {:ok, client_id, secret, assertion} <- client_credentials(conn, params),
         :ok <- OAuth.authenticate_client(client_id, secret, auth_opts(conn, assertion)) do
      case params["refresh_token"] do
        raw when is_binary(raw) and raw != "" ->
          ip = RequestMeta.format_ip(RemoteIp.resolve(conn))

          OAuth.rotate_refresh_token(raw, client_id, ip: ip)
          |> grant_result(conn, :refresh_token, client_id)

        _ ->
          reject(conn, :refresh_token, client_id, "invalid_request", :refresh_token_missing)
      end
    else
      {:error, reason} -> auth_error(conn, :refresh_token, reason)
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

  defp clear_request_state(conn, _opts) do
    forget_request_state()

    register_before_send(conn, fn conn ->
      forget_request_state()
      conn
    end)
  end

  defp forget_request_state do
    _ = JwksCache.take_source()
    _ = OAuth.take_grant_user_id()
    :ok
  end

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

  # RFC 7523 §3 permits either the token endpoint URL or the issuer identifier
  # in `aud`. Both are derived from the host the client actually dialed, so a
  # backend fronting several canonical domains never demands an audience the
  # client had no way to name.
  defp auth_opts(_conn, nil), do: []

  defp auth_opts(conn, assertion) do
    base = OAuthMetadata.base_url(conn)
    [assertion: assertion, audiences: [base <> "/oauth/token", base]]
  end

  # RFC 6749 §2.3.1: the Basic header is the preferred channel, the body is the
  # `client_secret_post` alternative. A caller must not use both at once, since
  # the two could disagree and we would have to pick a winner silently.
  #
  # RFC 7521 §4.2 adds a third channel. An assertion carries the client's
  # identity in its own signed `iss`/`sub`, which is why `client_id` is optional
  # beside it — but it is still a credential, so presenting one alongside a
  # secret is refused for exactly the reason Basic-plus-body is.
  defp client_credentials(conn, params) do
    body_id = blank_to_nil(params["client_id"])
    body_secret = blank_to_nil(params["client_secret"])
    assertion = blank_to_nil(params["client_assertion"])

    case assertion do
      nil ->
        with {:ok, id, secret} <- secret_credentials(conn, body_id, body_secret),
             do: {:ok, id, secret, nil}

      _ ->
        assertion_credentials(conn, params, body_id, body_secret, assertion)
    end
  end

  # An unrecognised `client_assertion_type` is refused rather than ignored:
  # ignoring it would silently fall through to "public client, no credential"
  # and authenticate a caller that believed it was proving something.
  #
  # Every branch logs. These rejections happen BEFORE `authenticate_client/3`,
  # so without a line here the highest-probability interop failure in this path
  # — a vendor sending a draft-era or whitespace-padded `client_assertion_type`
  # — 401s forever and produces no evidence anywhere. That is #1633 repeating
  # one layer down.
  defp assertion_credentials(conn, params, body_id, body_secret, assertion) do
    cond do
      blank_to_nil(params["client_assertion_type"]) != Jwks.assertion_type() ->
        reject_malformed(:client_assertion_type_unrecognised, body_id)

      not is_nil(body_secret) ->
        reject_malformed(:secret_presented_with_assertion, body_id)

      Plug.BasicAuth.parse_basic_auth(conn) != :error ->
        reject_malformed(:basic_auth_presented_with_assertion, body_id)

      true ->
        resolve_assertion_client(body_id, assertion)
    end
  end

  defp resolve_assertion_client(body_id, assertion) do
    case body_id || assertion_issuer(assertion) do
      nil -> reject_malformed(:assertion_issuer_unreadable, body_id)
      client_id -> {:ok, client_id, nil, assertion}
    end
  end

  # Through `OAuth.log_refusal/3` rather than a hand-rolled line, which is what
  # this was: the one refusal emitter on this path with no `cimd_host` key, so a
  # host-faceted alert dropped every malformed-assertion refusal silently.
  defp reject_malformed(reason, client_id) do
    OAuth.log_refusal("oauth_client_assertion_malformed", client_id, reason)
    {:error, :invalid_client}
  end

  # Unverified at this point — it only picks WHICH client's published keys the
  # signature is then checked against, and a wrong guess fails that check.
  defp assertion_issuer(assertion) do
    case Joken.peek_claims(assertion) do
      {:ok, %{"iss" => iss}} when is_binary(iss) -> iss
      _ -> nil
    end
  end

  defp secret_credentials(conn, body_id, body_secret) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {basic_id, basic_secret} ->
        if is_nil(body_secret) and (is_nil(body_id) or body_id == basic_id) do
          {:ok, blank_to_nil(basic_id), blank_to_nil(basic_secret)}
        else
          # The one branch in this module that used to refuse silently, despite
          # the "Every branch logs" rule above it. A vendor sending its id in
          # both channels with a typo in one 401s on every exchange, and before
          # this there was nothing in Loki but the 401 request line (#1643).
          OAuth.reject_client(basic_id, :basic_and_body_credential_conflict)
        end

      :error ->
        {:ok, body_id, body_secret}
    end
  end

  # An empty secret is "no secret", not "the secret is the empty string".
  # Some OAuth libraries send `Basic base64("client_id:")` for public clients;
  # treating that as a presented credential would reject them, because a public
  # client presenting a secret is refused. Costs nothing: "" can never match a
  # stored hash, so a confidential client is still rejected either way.
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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

  defp maybe_challenge(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> _ | _] -> put_resp_header(conn, "www-authenticate", ~s(Basic realm="oauth"))
      _ -> conn
    end
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
