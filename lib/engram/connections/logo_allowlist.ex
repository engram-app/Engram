defmodule Engram.Connections.LogoAllowlist do
  @moduledoc """
  Compile-time map of trusted `software_id` values → display metadata.
  Unknown ids return an unverified placeholder so the UI can render an
  "Unverified client" badge.
  """

  @allowlist %{
    "engram-vault-sync" => %{logo: "/assets/clients/engram-vault-sync.svg", display_name: "Obsidian Vault Sync"},
    "anthropic-claude-desktop" => %{logo: "/assets/clients/claude.svg", display_name: "Claude Desktop"},
    "cursor.sh" => %{logo: "/assets/clients/cursor.svg", display_name: "Cursor"},
    "openai-chatgpt" => %{logo: "/assets/clients/chatgpt.svg", display_name: "ChatGPT"},
    "vscode-engram" => %{logo: "/assets/clients/vscode.svg", display_name: "VS Code (Engram)"}
  }

  @spec lookup(String.t() | nil) :: %{verified: boolean(), logo: String.t() | nil, display_name: String.t() | nil}
  def lookup(software_id) when is_binary(software_id) do
    case Map.get(@allowlist, software_id) do
      nil -> %{verified: false, logo: nil, display_name: nil}
      entry -> Map.merge(%{verified: true}, entry)
    end
  end

  def lookup(_), do: %{verified: false, logo: nil, display_name: nil}
end
