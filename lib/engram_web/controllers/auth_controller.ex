defmodule EngramWeb.AuthController do
  use EngramWeb, :controller

  alias Engram.Accounts

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
