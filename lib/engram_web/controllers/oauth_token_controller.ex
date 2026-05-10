defmodule EngramWeb.OAuthTokenController do
  @moduledoc """
  RFC 6749 §3.2 token endpoint. Public client + PKCE today; mounted under
  `:oauth_api` (rate-limited per IP). Accepts both
  `application/x-www-form-urlencoded` and `application/json` bodies via the
  endpoint's standard parsers.
  """
  use EngramWeb, :controller

  alias Engram.OAuth

  def exchange(conn, %{"grant_type" => "authorization_code"} = params) do
    case OAuth.exchange_authorization_code(params) do
      {:ok, response} ->
        json(conn, response)

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_grant"})
    end
  end

  def exchange(conn, %{"grant_type" => "refresh_token"} = params) do
    case params["refresh_token"] do
      raw when is_binary(raw) and raw != "" ->
        do_refresh(conn, raw, params["client_id"])

      _ ->
        invalid_request(conn)
    end
  end

  def exchange(conn, %{"grant_type" => _other}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "unsupported_grant_type"})
  end

  def exchange(conn, _params), do: invalid_request(conn)

  defp do_refresh(conn, raw_token, client_id) do
    case OAuth.rotate_refresh_token(raw_token, client_id) do
      {:ok, response} ->
        json(conn, response)

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_grant"})
    end
  end

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request"})
  end
end
