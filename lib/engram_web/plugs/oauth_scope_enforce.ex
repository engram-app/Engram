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
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Engram.Accounts.verify_jwt(token) do
      conn
      |> assign(:oauth_scope_vault_ids, scope_ids(claims))
      |> assign(:oauth_scope, claims["scope"])
    else
      _ -> conn
    end
  end

  # Reads the list claim, falling back to the scalar one so refresh tokens
  # minted before multi-vault grants shipped keep their binding. An empty
  # list is treated as unrestricted rather than "no vaults": it is never
  # written (mint rejects it), so encountering one means a malformed token,
  # and the surrounding API-key and ownership checks still apply.
  defp scope_ids(%{"vault_ids" => ids}) when is_list(ids) and ids != [],
    do: Enum.map(ids, &to_string/1)

  defp scope_ids(%{"vault_id" => id}) when is_binary(id), do: [id]
  defp scope_ids(_), do: nil
end
