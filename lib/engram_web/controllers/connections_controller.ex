defmodule EngramWeb.ConnectionsController do
  @moduledoc """
  Unified read of user's active credentials: OAuth refresh tokens
  (Obsidian plugin + MCP clients) and PATs (api_keys), grouped and
  enriched for the /settings/connections page.

  Session-only — JWT auth, never API-key auth. A PAT must not be able to
  enumerate or alter its sibling credentials.
  """
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Engram.Connections
  alias EngramWeb.Schemas

  plug EngramWeb.Plugs.EnforcePatCreation when action in [:create_pat]

  operation(:index,
    operation_id: "connections-list",
    summary: "List active connections",
    tags: ["Connections"],
    description: "OAuth client families, device families, and PATs. Session-auth only.",
    responses: [ok: {"Connections", "application/json", Schemas.ConnectionsList}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Enum.map(Connections.list_for_user(user), &serialize/1))
  end

  operation(:delete_oauth,
    operation_id: "connections-delete-oauth",
    summary: "Revoke an OAuth client connection",
    description:
      "Revokes the refresh tokens for an OAuth client family (e.g. an MCP client) so it can no " <>
        "longer mint access tokens. Pass `vault_id` to scope the revoke to a single vault; omit it " <>
        "to revoke the client across all vaults. Session-auth only.",
    tags: ["Connections"],
    parameters: [
      client_id: [in: :path, type: :string, required: true, description: "OAuth client id"],
      vault_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope revoke to one vault"
      ]
    ],
    responses: [
      no_content: "Revoked (empty body)",
      not_found: {"No such connection", "application/json", Schemas.MessageError}
    ]
  )

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

  operation(:create_pat,
    operation_id: "connections-create-pat",
    summary: "Create a personal access token",
    tags: ["Connections"],
    description: "The raw `key` is returned once. Subject to the per-plan PAT creation limit.",
    request_body: {"PAT name", "application/json", Schemas.CreatePatRequest, required: true},
    responses: [
      created: {"Created (raw key)", "application/json", Schemas.ApiKeyCreated},
      unprocessable_entity: {"Blank/invalid name", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete_device,
    operation_id: "connections-delete-device",
    summary: "Revoke a device connection",
    description:
      "Revokes a linked device family (e.g. an Obsidian plugin install) by its family id, " <>
        "invalidating its refresh tokens. Session-auth only.",
    tags: ["Connections"],
    parameters: [
      family_id: [in: :path, type: :string, required: true, description: "Device family id"]
    ],
    responses: [
      no_content: "Revoked (empty body)",
      not_found: {"No such connection", "application/json", Schemas.MessageError}
    ]
  )

  def delete_device(conn, %{"family_id" => family_id}) do
    user = conn.assigns.current_user

    case Connections.revoke_device_family(user.id, family_id) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  operation(:delete_pat,
    operation_id: "connections-delete-pat",
    summary: "Revoke a personal access token",
    description:
      "Revokes the personal access token (API key) with the given UUID so it can no longer " <>
        "authenticate. Returns 404 for an unknown or malformed id. Session-auth only.",
    tags: ["Connections"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "PAT (API key) UUID"]
    ],
    responses: [
      no_content: "Revoked (empty body)",
      not_found: {"No such PAT", "application/json", Schemas.MessageError}
    ]
  )

  def delete_pat(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user

    with {:ok, id} <- Ecto.UUID.cast(id_str),
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
    case Ecto.UUID.cast(v) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

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
      slug: row.slug,
      vault_id: row.vault_id,
      vault_name: row.vault_name,
      scope: row.scope,
      last_used_at: row.last_used_at,
      connected_at: row.connected_at,
      first_user_agent: row.first_user_agent,
      first_ip: row.first_ip,
      redirect_uris: row.redirect_uris
    }
  end
end
