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

  plug EngramWeb.Plugs.EnforcePatCreation when action in [:create_pat]

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Enum.map(Connections.list_for_user(user.id), &serialize/1))
  end

  def delete_oauth(conn, %{"client_id" => client_id} = params) do
    user = conn.assigns.current_user
    vault_id = parse_vault_id(params["vault_id"])

    case Connections.revoke_oauth_family(user.id, client_id, vault_id) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  def create_pat(conn, params) do
    user = conn.assigns.current_user
    name = Map.get(params, "name") || Map.get(params, :name)

    if is_nil(name) or name == "" do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{name: ["can't be blank"]}})
    else
      case Engram.Accounts.create_api_key(user, name) do
        {:ok, raw_key, api_key} ->
          conn
          |> put_status(:created)
          |> json(%{key: raw_key, id: api_key.id, name: api_key.name})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: EngramWeb.format_errors(changeset)})
      end
    end
  end

  def delete_pat(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user

    with {id, ""} <- Integer.parse(id_str),
         :ok <- Engram.Accounts.revoke_api_key(user, id) do
      send_resp(conn, 204, "")
    else
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp parse_vault_id(nil), do: nil
  defp parse_vault_id(""), do: nil

  defp parse_vault_id(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_vault_id(v) when is_integer(v), do: v
  defp parse_vault_id(_), do: nil

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
