defmodule EngramWeb.Plugs.OAuthScopeEnforce do
  @moduledoc """
  Surfaces OAuth scope claims (`vault_ids`, `scope`) from an Engram-issued
  internal HS256 JWT (the kind minted by `/oauth/token`) so downstream
  callers can enforce the grant's vault scope on the bearer token.

  Mounted on `/api/mcp` and on the vault-scoped REST pipeline, AFTER
  `EngramWeb.Plugs.Auth`. Auth has already validated the token, so this
  plug re-parses to extract the OAuth-specific claims without a second DB
  hit.

  Sets `conn.assigns.oauth_scope_vault_ids` (a list of vault id strings, or
  nil for an unrestricted grant), `conn.assigns.oauth_scope` (string or
  nil), and `conn.assigns.device_token` (true for a plugin device-flow
  token, read by `RequireSession`). Never halts — absence of OAuth claims is the normal case for
  API-key / Clerk JWT auth, and means unrestricted.

  The claim shapes are normalized by `Engram.Permissions.scope_ids_from_claims/1`,
  shared with `UserSocket` so the HTTP and WebSocket assigns cannot drift.
  """
  import Plug.Conn

  @mcp_audience Engram.Token.mcp_audience()

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Engram.Accounts.verify_jwt(token) do
      conn
      |> assign(:oauth_scope_vault_ids, Engram.Permissions.scope_ids_from_claims(claims))
      |> assign(:oauth_scope, claims["scope"])
      |> assign(:device_token, claims["cred"] == "device")
      |> require_mcp_scope(claims)
    else
      _ -> conn
    end
  end

  # An MCP-audience token must also carry the `mcp` scope. Every grant does
  # today (`OAuth.narrow_scope/1` always keeps it), so this is a guard, not a
  # behaviour change: RFC 6750 §3.1's 403 if a token ever arrives without it.
  defp require_mcp_scope(conn, %{"aud" => @mcp_audience} = claims) do
    if "mcp" in String.split(claims["scope"] || "", " ", trim: true) do
      conn
    else
      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer error="insufficient_scope", scope="mcp")
      )
      |> EngramWeb.Plugs.Halt.json(403, %{error: "insufficient_scope"})
    end
  end

  defp require_mcp_scope(conn, _claims), do: conn
end
