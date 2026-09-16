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

  alias Engram.Connections.LogoAllowlist
  alias Engram.OAuth

  action_fallback EngramWeb.FallbackController

  def show(conn, %{"client_id" => client_id} = params) do
    with {:ok, client} <- OAuth.get_client(client_id) do
      # `kind` is "mcp" | "obsidian" — drives the proactive cap UI on
      # /oauth/consent (each kind has its own cap key). DCR rejects
      # "obsidian", but device-flow clients may carry that kind.
      json(conn, %{
        client_id: client.client_id,
        client_name: client.client_name,
        kind: client.kind,
        slug: slug_for(client, params["redirect_uri"])
      })
    end
  end

  # The catalog slug for the connecting client, so an MCP-first signup can
  # answer the FTUX tool question from the connection itself instead of asking
  # a question the user has already answered by being here.
  #
  # `LogoAllowlist.resolve/4` derives identity from the ONE redirect the grant
  # is using, never from the registered list — scanning the list for any vendor
  # host is exactly what #1204 was. The redirect arrives as a caller-supplied
  # query param here, so it is honored only when the client actually registered
  # it; anything else is dropped rather than trusted, and resolution falls back
  # to what the stored record can prove on its own.
  #
  # Nil is a normal answer (an unattributable client), not an error.
  defp slug_for(client, redirect_uri) do
    registered = client.redirect_uris || []
    uri = if redirect_uri in registered, do: redirect_uri

    LogoAllowlist.resolve(client.software_id, uri, client.client_name, client.cimd_url).slug
  end
end
