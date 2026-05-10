defmodule EngramWeb.Plugs.OAuthScopeEnforce do
  @moduledoc """
  Surfaces OAuth scope claims (`vault_id`, `scope`) from an Engram-issued
  internal HS256 JWT (the kind minted by `/oauth/token`) so downstream
  controllers can enforce vault-scope locks on the bearer token.

  Mounted only on `/api/mcp`, AFTER `EngramWeb.Plugs.Auth`. Auth has
  already validated the token, so this plug re-parses to extract the
  OAuth-specific claims without a second DB hit.

  Sets `conn.assigns.oauth_scope_vault_id` (integer or nil) and
  `conn.assigns.oauth_scope` (string or nil). Never halts — absence
  of OAuth claims is the normal case for API-key / Clerk JWT auth.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Engram.Accounts.verify_jwt(token) do
      conn
      |> assign(:oauth_scope_vault_id, claims["vault_id"])
      |> assign(:oauth_scope, claims["scope"])
    else
      _ -> conn
    end
  end
end
