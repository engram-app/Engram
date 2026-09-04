defmodule EngramWeb.Plugs.RequireSession do
  @moduledoc """
  Requires that the request is authenticated by a first-party session, not by a
  delegated credential. Use on routes that manage credentials or other
  account-wide primitives.

  Two credential kinds are rejected, for the same reason:

    * **API keys** — a key restricted to one vault must not be able to
      enumerate, create, or revoke other API keys for the same user.
    * **OAuth grants** — a third-party app holding a grant scoped to some
      vaults must not be able to mint an UNRESTRICTED API key for itself, nor
      revoke the user's other connections. Issuing yourself a broader
      credential than your grant is privilege escalation, so an all-vaults
      grant is rejected too: it is still a third-party app.

  Assumes `EngramWeb.Plugs.Auth` and `EngramWeb.Plugs.OAuthScopeEnforce` have
  already run. The OAuth grant is discriminated on `:oauth_scope` (the token's
  `scope` claim) and NOT on "is this an internal JWT" — local/self-host session
  tokens and device-flow tokens are internal JWTs too, and blocking those would
  lock every self-host user out of their own settings page. Neither carries a
  `scope` claim; only `Engram.OAuth.issue_access_token/3` sets one.

  The two rejections carry distinct error codes so they stay separable in logs
  and in the client.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      conn.assigns[:current_api_key] -> reject(conn, "api_key_not_allowed")
      conn.assigns[:oauth_scope] -> reject(conn, "oauth_grant_not_allowed")
      true -> conn
    end
  end

  defp reject(conn, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: error}))
    |> halt()
  end
end
