defmodule EngramWeb.OAuthRevokeController do
  @moduledoc """
  RFC 7009 token revocation.

  The client authenticates exactly as at `/oauth/token` (§2.1): body
  `client_id`, HTTP Basic, or a `private_key_jwt` assertion. A failure is
  RFC 6749 §5.2 `invalid_client` (401), a missing `token` is
  `invalid_request` (400).

  Once authenticated the answer is always 200 (§2.2), whether or not the token
  existed, so the endpoint never confirms which tokens are live. Only refresh
  tokens are stored server-side, so revoking an access token is a no-op; it
  expires within 15 minutes on its own. A token owned by another client is also
  a 200 no-op.
  """
  use EngramWeb, :controller

  import EngramWeb.OAuthClientAuth, only: [clear_request_state: 2, blank_to_nil: 1]

  alias Engram.OAuth
  alias EngramWeb.OAuthClientAuth

  plug :clear_request_state

  def revoke(conn, params) do
    case OAuthClientAuth.authenticate(conn, params) do
      {:ok, client_id} ->
        case blank_to_nil(params["token"]) do
          nil ->
            conn |> put_status(:bad_request) |> json(%{error: "invalid_request"})

          token ->
            _ = OAuth.revoke_token(token, client_id, params["token_type_hint"])
            send_resp(conn, 200, "")
        end

      {:error, :temporarily_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "temporarily_unavailable"})

      {:error, :invalid_client} ->
        conn
        |> maybe_challenge()
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_client"})
    end
  end

  defp maybe_challenge(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> _ | _] -> put_resp_header(conn, "www-authenticate", ~s(Basic realm="oauth"))
      _ -> conn
    end
  end
end
