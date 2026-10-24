defmodule EngramWeb.FrontendUrl do
  @moduledoc """
  Absolute URLs on the web app (SPA) host.

  On SaaS the SPA lives on its own origin (`ENGRAM_FRONTEND_URL`, i.e.
  `:frontend_base_url`, app.engram.page) while the backend answers on
  api./mcp.engram.page, so a link built from this endpoint's host would 404.
  Self-host leaves it unset and serves both from one origin, so the endpoint
  URL is right there. Copy that sends a user to the web app (emails, MCP
  errors, onboarding redirects) builds its link here.
  """

  @spec base() :: String.t()
  def base do
    case Application.get_env(:engram, :frontend_base_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> EngramWeb.Endpoint.url()
    end
  end

  @spec url(String.t()) :: String.t()
  def url("/" <> _ = path), do: base() <> path

  @doc """
  What to tell a user whose account has no vault yet. One copy for every
  surface that hits it (MCP tool calls, the REST vault plug).
  """
  @spec no_vault_message() :: String.t()
  def no_vault_message,
    do:
      "No vault found: this account has no vault yet. Create one in the Engram web app at " <>
        "#{url("/onboard")}, or install the Engram Vault Sync plugin in Obsidian and link it " <>
        "to your account, which creates a vault from your Obsidian vault. Then try again."
end
