defmodule EngramWeb.ConnectionsController do
  @moduledoc """
  Unified read of user's active credentials: OAuth refresh tokens
  (Obsidian plugin + MCP clients) and PATs (api_keys), grouped and
  enriched for the /settings/connections page.

  Session-only — JWT auth, never API-key auth. A PAT must not be able to
  enumerate or alter its sibling credentials.
  """
  use EngramWeb, :controller
  alias Engram.Connections

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Enum.map(Connections.list_for_user(user.id), &serialize/1))
  end

  defp serialize(row) do
    %{
      kind: Atom.to_string(row.kind),
      client_id: row.client_id,
      key_id: row.key_id,
      name: row.name,
      software_id: row.software_id,
      software_version: row.software_version,
      verified: row.verified,
      logo: row.logo,
      vault_id: row.vault_id,
      scope: row.scope,
      last_used_at: row.last_used_at,
      connected_at: row.connected_at,
      first_user_agent: row.first_user_agent,
      first_ip: row.first_ip,
      redirect_uris: row.redirect_uris
    }
  end
end
