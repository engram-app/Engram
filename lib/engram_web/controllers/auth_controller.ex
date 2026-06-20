defmodule EngramWeb.AuthController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Engram.Accounts
  alias EngramWeb.Schemas

  operation(:list_api_keys,
    operation_id: "apikeys-list",
    summary: "List API keys",
    tags: ["API Keys"],
    responses: [ok: {"API keys", "application/json", Schemas.ApiKeysResponse}]
  )

  def list_api_keys(conn, _params) do
    user = conn.assigns.current_user
    keys = Accounts.list_api_keys(user)

    json(conn, %{
      keys:
        Enum.map(keys, fn k ->
          %{
            id: k.id,
            name: k.name,
            created_at: k.created_at,
            last_used: k.last_used
          }
        end)
    })
  end

  operation(:create_api_key,
    operation_id: "apikeys-create",
    summary: "Create an API key",
    tags: ["API Keys"],
    description: "The raw `key` is returned once in this response and never again.",
    request_body: {"Key name", "application/json", Schemas.CreateApiKeyRequest, required: true},
    responses: [
      ok: {"Created (raw key)", "application/json", Schemas.ApiKeyCreated},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create_api_key(conn, %{"name" => name}) do
    user = conn.assigns.current_user

    case Accounts.create_api_key(user, name) do
      {:ok, raw_key, api_key} ->
        json(conn, %{key: raw_key, name: api_key.name, id: api_key.id})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:revoke_api_key,
    operation_id: "apikeys-revoke",
    summary: "Revoke an API key",
    tags: ["API Keys"],
    parameters: [id: [in: :path, type: :string, required: true, description: "API key UUID"]],
    responses: [
      ok: {"Revoked", "application/json", Schemas.DeletedFlag},
      bad_request: {"Invalid id", "application/json", Schemas.MessageError},
      not_found: {"No such key", "application/json", Schemas.MessageError}
    ]
  )

  def revoke_api_key(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Accounts.revoke_api_key(user, uuid) do
          :ok ->
            json(conn, %{deleted: true})

          {:error, _} ->
            conn |> put_status(404) |> json(%{error: "API key not found"})
        end

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid API key id"})
    end
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)
end
