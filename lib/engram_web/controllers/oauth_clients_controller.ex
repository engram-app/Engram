defmodule EngramWeb.OAuthClientsController do
  @moduledoc """
  Public read-only metadata for registered OAuth clients.

  The SPA consent UI (`/oauth/consent`) calls this to render
  *"Authorize **<client_name>** to access your Engram"* without
  exposing the human-readable name in the URL bar.

  Surfaces only `client_id` + `client_name`. Never `client_secret`,
  `redirect_uris`, or scope metadata. Public — `client_id` is itself
  public (returned by DCR), and `client_name` is non-secret. Rate
  limited at the router level to deter enumeration.
  """
  use EngramWeb, :controller

  alias Engram.OAuth

  def show(conn, %{"client_id" => client_id}) do
    case OAuth.get_client(client_id) do
      {:ok, client} ->
        # `kind` is "mcp" | "obsidian" — drives the proactive cap UI on
        # /oauth/consent (each kind has its own cap key). DCR rejects
        # "obsidian", but device-flow clients may carry that kind.
        json(conn, %{
          client_id: client.client_id,
          client_name: client.client_name,
          kind: client.kind
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end
end
