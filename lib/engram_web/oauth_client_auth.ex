defmodule EngramWeb.OAuthClientAuth do
  @moduledoc """
  Client authentication shared by `/oauth/token` and `/oauth/revoke`.

  RFC 7009 §2.1 requires revocation to authenticate the client the same way the
  token endpoint does. Revoke used to read only the body `client_id`, so a
  client that authenticated with HTTP Basic or an assertion got a 200 and kept
  its grant (#1977).
  """
  import Plug.Conn

  alias Engram.OAuth
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Cimd.JwksCache
  alias EngramWeb.OAuthMetadata

  @doc "Resolves and verifies the calling client. Returns its wire `client_id`."
  @spec authenticate(Plug.Conn.t(), map()) ::
          {:ok, String.t() | nil} | {:error, :invalid_client | :temporarily_unavailable}
  def authenticate(conn, params) do
    with {:ok, client_id, secret, assertion} <- client_credentials(conn, params),
         :ok <- OAuth.authenticate_client(client_id, secret, auth_opts(conn, assertion)) do
      {:ok, client_id}
    end
  end

  @doc """
  Plug. The JWKS source and the grant's user live in the request process (they
  are set several frames below the controller). A keep-alive connection reuses
  that process, so both are cleared before every request and again as the
  response goes out, whatever the outcome (#1974 review #13).
  """
  def clear_request_state(conn, _opts) do
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
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value
end
