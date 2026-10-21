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

  action_fallback EngramWeb.FallbackController

  operation(:index,
    operation_id: "connections-list",
    summary: "List active connections",
    tags: ["Connections"],
    description: "OAuth client families, device families, and PATs. Session-auth only.",
    responses: [ok: {"Connections", "application/json", Schemas.ConnectionsList}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    # Vault names resolve through the request's grant, not the user's whole
    # vault list. `RequireSession` now rejects OAuth grants outright, so this is
    # defence in depth — it still covers a grant whose `scope` claim is NULL,
    # which the plug cannot discriminate.
    scope = Engram.Permissions.vault_scope(conn)
    json(conn, Enum.map(Connections.list_for_user(user, scope), &serialize/1))
  end

  operation(:delete_oauth,
    operation_id: "connections-delete-oauth",
    summary: "Revoke an OAuth client connection",
    description:
      "Revokes the refresh tokens for an OAuth client family (e.g. an MCP client) so it can no " <>
        "longer mint access tokens. Pass `family_id` to revoke ONE grant — a client the user " <>
        "authorized twice has two, and each is its own row in `GET /connections`. Omit it to " <>
        "disconnect the client entirely, which is what frees a connection-cap slot. `vault_id` " <>
        "is the older, coarser narrowing and is ignored when `family_id` is given: it revokes, " <>
        "whole, each of the client's grants that can reach that vault. A grant with per-vault " <>
        "levels counts as reaching it at read or write, and through its new-vaults policy; a " <>
        "grant that lists vaults without levels, when the vault is one of them; and an " <>
        "all-vaults grant, which reaches every vault. A revoked grant's access tokens stop " <>
        "working at once and its live sockets are disconnected. Session-auth only.",
    tags: ["Connections"],
    parameters: [
      client_id: [in: :path, type: :string, required: true, description: "OAuth client id"],
      family_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Revoke only this grant lineage"
      ],
      vault_id: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Revoke only the grants that can reach this vault, all-vaults grants included"
      ]
    ],
    responses: [
      no_content: "Revoked (empty body)",
      not_found: {"No such connection", "application/json", Schemas.MessageError}
    ]
  )

  def delete_oauth(conn, %{"client_id" => client_id} = params) do
    user = conn.assigns.current_user

    # A `family_id` names one grant lineage, so it revokes exactly the row the
    # user clicked. Without it this stays client-wide: that is the "disconnect
    # this app entirely" behaviour the cap-swap flows depend on, since the cap
    # counts clients, not grants.
    result =
      case parse_uuid(params["family_id"]) do
        nil -> Connections.revoke_oauth_family(user.id, client_id, parse_uuid(params["vault_id"]))
        family_id -> Connections.revoke_oauth_grant(user.id, family_id)
      end

    with :ok <- result do
      track_oauth_revoked(user, client_id)
      send_resp(conn, 204, "")
    end
  end

  # Connection churn: an Obsidian OAuth grant is a device, anything else an
  # MCP client (bucketed to its family, never the client's own name).
  defp track_oauth_revoked(user, client_id) do
    case Engram.OAuth.get_client(client_id) do
      {:ok, %{kind: "obsidian"}} ->
        Engram.Analytics.track(user, "device_disconnected", %{via: "oauth"})

      {:ok, client} ->
        {family, _registration} = Engram.Analytics.McpClient.of_client(client)
        Engram.Analytics.track(user, "mcp_client_disconnected", %{via: "oauth", client: family})

      _ ->
        :ok
    end
  end

  operation(:create_pat,
    operation_id: "connections-create-pat",
    summary: "Create a personal access token",
    tags: ["Connections"],
    description:
      "The raw `key` is returned once. Any plan can create a key, and it works on every route " <>
        "(REST, MCP, sync sockets) on every plan, rate limited per user (`api_rps_cap`).",
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
      with {:ok, access} <- EngramWeb.KeyAccessParams.parse(conn, params) do
        case Engram.Accounts.create_api_key(user, name, access) do
          {:ok, raw_key, api_key} ->
            conn
            |> put_status(:created)
            |> json(
              Map.merge(
                %{key: raw_key, id: api_key.id, name: api_key.name},
                Engram.Permissions.key_params(api_key)
              )
            )

          {:error, %Ecto.Changeset{}} = error ->
            error

          {:error, :invalid_access} ->
            EngramWeb.KeyAccessParams.invalid(conn)
        end
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

    with :ok <- Connections.revoke_device_family(user.id, family_id) do
      Engram.Analytics.track(user, "device_disconnected", %{via: "device_flow"})
      send_resp(conn, 204, "")
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
      Engram.Analytics.track(user, "mcp_client_disconnected", %{via: "api_key"})
      send_resp(conn, 204, "")
    else
      # Malformed UUID and revoke errors alike render the same 404.
      _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  operation(:update_oauth,
    operation_id: "connections-update-oauth",
    summary: "Change an OAuth connection's vault access",
    description:
      "Replaces the vault levels of ONE grant (`family_id`) of an OAuth client. Takes effect " <>
        "at once: issued access tokens and every later refresh carry the new access, and the " <>
        "user's live sockets reconnect. Widening is allowed. A grant the client asked to be " <>
        "read only (`mcp:read`) cannot be given write: 422. Session-auth only.",
    tags: ["Connections"],
    parameters: [
      client_id: [in: :path, type: :string, required: true, description: "OAuth client id"],
      family_id: [in: :query, type: :string, required: true, description: "The grant to change"]
    ],
    request_body: {"New access", "application/json", Schemas.UpdateAccessRequest, required: true},
    responses: [
      ok: {"The updated connection", "application/json", Schemas.Connection},
      bad_request: {"Missing family_id", "application/json", Schemas.MessageError},
      not_found: {"No such connection", "application/json", Schemas.MessageError},
      unprocessable_entity: {"Access the grant cannot have", "application/json", Schemas.Error}
    ]
  )

  def update_oauth(conn, %{"client_id" => client_id} = params) do
    user = conn.assigns.current_user

    with {:family, family_id} when is_binary(family_id) <-
           {:family, parse_uuid(params["family_id"])},
         {:ok, selection} <- leveled_access(conn, params) do
      case Connections.update_oauth_grant_access(user, client_id, family_id, selection) do
        :ok ->
          Engram.Analytics.track(user, "oauth_grant_access_changed", %{})
          render_row(conn, &(&1.family_id == family_id and &1.kind != :pat))

        {:error, :not_found} ->
          not_found(conn)

        {:error, :invalid_access} ->
          EngramWeb.KeyAccessParams.invalid(conn)

        {:error, :read_only_grant} ->
          read_only_grant(conn)
      end
    else
      {:family, nil} -> conn |> put_status(:bad_request) |> json(%{error: "family_id_required"})
      %Plug.Conn{} = halted -> halted
    end
  end

  operation(:update_pat,
    operation_id: "connections-update-pat",
    summary: "Change a personal access token's vault access",
    description:
      "Replaces the vault levels of a key created with levels (`engram_lk_`). The raw key is " <>
        "unchanged, and the change takes effect at once. A key created before levels cannot be " <>
        "changed (422); create a new key instead. 404 for an unknown or malformed id. " <>
        "Session-auth only.",
    tags: ["Connections"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "PAT (API key) UUID"]
    ],
    request_body: {"New access", "application/json", Schemas.UpdateAccessRequest, required: true},
    responses: [
      ok: {"The updated connection", "application/json", Schemas.Connection},
      not_found: {"No such PAT", "application/json", Schemas.MessageError},
      unprocessable_entity: {"Access the key cannot have", "application/json", Schemas.Error}
    ]
  )

  def update_pat(conn, %{"id" => id_str} = params) do
    user = conn.assigns.current_user

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         {:ok, selection} <- leveled_access(conn, params) do
      case Engram.Accounts.update_api_key_access(user, id, selection) do
        {:ok, _key} ->
          Engram.Analytics.track(user, "api_key_access_changed", %{})
          render_row(conn, &(&1.kind == :pat and &1.key_id == id))

        {:error, :not_found} ->
          not_found(conn)

        {:error, :invalid_access} ->
          EngramWeb.KeyAccessParams.invalid(conn)

        {:error, :legacy_key} ->
          legacy_key(conn)
      end
    else
      :error -> not_found(conn)
      %Plug.Conn{} = halted -> halted
    end
  end

  # An edit always says what the credential gets: no params is not "all vaults".
  defp leveled_access(conn, params) do
    case EngramWeb.KeyAccessParams.parse(conn, params) do
      {:ok, nil} -> EngramWeb.KeyAccessParams.invalid(conn)
      {:ok, selection} -> {:ok, selection}
      halted -> halted
    end
  end

  # The row as `GET /connections` serializes it, so the client can patch its cache.
  defp render_row(conn, match?) do
    scope = Engram.Permissions.vault_scope(conn)

    case conn.assigns.current_user |> Connections.list_for_user(scope) |> Enum.find(match?) do
      nil -> not_found(conn)
      row -> json(conn, serialize(row))
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp read_only_grant(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: %{
        vault_access: ["this connection asked for read-only access and cannot be given write"]
      }
    })
  end

  defp legacy_key(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: %{
        vault_access: ["this key was created before access levels; create a new key instead"]
      }
    })
  end

  defp parse_uuid(nil), do: nil
  defp parse_uuid(""), do: nil

  defp parse_uuid(v) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_uuid(_), do: nil

  defp serialize(row) do
    %{
      kind: Atom.to_string(row.kind),
      client_id: row.client_id,
      # The grant this row IS. `client_id` can be shared by several rows; this
      # is what the row's own Disconnect keys on.
      family_id: row.family_id,
      key_id: row.key_id,
      name: row.name,
      label: row.label,
      software_id: row.software_id,
      software_version: row.software_version,
      verified: row.verified,
      logo: row.logo,
      slug: row.slug,
      # Always arrays (or nil for "all vaults"), on every kind — a payload
      # where one branch emits a list and another a scalar is a frontend bug
      # waiting to happen.
      vault_ids: row.vault_ids,
      vault_names: row.vault_names,
      scope: row.scope,
      vault_levels: row.vault_levels,
      new_vaults: row.new_vaults,
      last_used_at: row.last_used_at,
      connected_at: row.connected_at,
      first_user_agent: row.first_user_agent,
      first_ip: row.first_ip,
      # Where this grant's code was actually delivered, vs. everything the
      # client registered. Shown separately because the registered list is what
      # #1204 abused: an attacker's grant listed Anthropic's callback among its
      # redirects while the code went to their own loopback.
      redirect_uri: row.redirect_uri,
      redirect_uris: row.redirect_uris,
      # A CIMD client's PUBLIC identifier is this URL; `client_id` is the internal
      # UUID the revoke button keys on. The UI shows the URL because it is the
      # thing the user can actually verify by visiting it.
      cimd_url: row.cimd_url
    }
  end
end
