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
  nil for an unrestricted grant) and `conn.assigns.oauth_scope` (string or
  nil). Never halts — absence of OAuth claims is the normal case for
  API-key / Clerk JWT auth, and means unrestricted.

  The claim shapes are normalized by `Engram.Permissions.scope_ids_from_claims/1`,
  shared with `UserSocket` so the HTTP and WebSocket assigns cannot drift.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Engram.Accounts.verify_jwt(token) do
      conn
      |> assign(:oauth_scope_vault_ids, Engram.Permissions.scope_ids_from_claims(claims))
      |> assign(:oauth_scope, claims["scope"])
    else
      _ -> conn
    end
  end
end
