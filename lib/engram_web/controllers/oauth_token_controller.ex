defmodule EngramWeb.OAuthTokenController do
  @moduledoc """
  RFC 6749 §3.2 token endpoint. Public client + PKCE today; mounted under
  `:oauth_api` (rate-limited per IP). Accepts both
  `application/x-www-form-urlencoded` and `application/json` bodies via the
  endpoint's standard parsers.
  """
  use EngramWeb, :controller

  alias Engram.OAuth
  alias EngramWeb.RequestMeta

  def exchange(conn, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, client_id, secret} <- client_credentials(conn, params),
         :ok <- OAuth.authenticate_client(client_id, secret) do
      ip = RequestMeta.format_ip(conn.remote_ip)

      # Feed back the RESOLVED client_id: it may have arrived via HTTP Basic
      # rather than the body, and the grant check compares the code's client
      # against this param. Reading the body directly would fail every
      # Basic-authenticated exchange that omits the redundant body field.
      case OAuth.exchange_authorization_code(Map.put(params, "client_id", client_id), ip: ip) do
        {:ok, response} ->
          json(conn, response)

        {:error, _reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "invalid_grant"})
      end
    else
      {:error, :invalid_client} -> invalid_client(conn)
    end
  end

  def exchange(conn, %{"grant_type" => "refresh_token"} = params) do
    with {:ok, client_id, secret} <- client_credentials(conn, params),
         :ok <- OAuth.authenticate_client(client_id, secret) do
      case params["refresh_token"] do
        raw when is_binary(raw) and raw != "" ->
          do_refresh(conn, raw, client_id)

        _ ->
          invalid_request(conn)
      end
    else
      {:error, :invalid_client} -> invalid_client(conn)
    end
  end

  def exchange(conn, %{"grant_type" => _other}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "unsupported_grant_type"})
  end

  def exchange(conn, _params), do: invalid_request(conn)

  defp do_refresh(conn, raw_token, client_id) do
    ip = RequestMeta.format_ip(conn.remote_ip)

    case OAuth.rotate_refresh_token(raw_token, client_id, ip: ip) do
      {:ok, response} ->
        json(conn, response)

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_grant"})
    end
  end

  # RFC 6749 §2.3.1: the Basic header is the preferred channel, the body is the
  # `client_secret_post` alternative. A caller must not use both at once, since
  # the two could disagree and we would have to pick a winner silently.
  defp client_credentials(conn, params) do
    body_id = blank_to_nil(params["client_id"])
    body_secret = blank_to_nil(params["client_secret"])

    case Plug.BasicAuth.parse_basic_auth(conn) do
      {basic_id, basic_secret} ->
        if is_nil(body_secret) and (is_nil(body_id) or body_id == basic_id) do
          {:ok, blank_to_nil(basic_id), blank_to_nil(basic_secret)}
        else
          {:error, :invalid_client}
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
  defp invalid_client(conn) do
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

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request"})
  end
end
