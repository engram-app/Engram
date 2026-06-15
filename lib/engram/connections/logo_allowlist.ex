defmodule Engram.Connections.LogoAllowlist do
  @moduledoc """
  Identity metadata for OAuth clients. Primary key is the RFC 7591
  `software_id`, but most MCP clients omit it — so `resolve/2` falls back to
  matching the `redirect_uri` host against a map of vendor-owned HTTPS hosts.

  A vendor HTTPS host is un-spoofable for grant delivery (the auth code lands
  at the vendor, not a forger), so a host match grants `verified: true`. Custom
  schemes (`cursor://`) and loopback never match the host map.

  Unknown ids/hosts return an unverified placeholder so the UI can render an
  "Unverified client" badge.
  """

  @empty %{verified: false, logo: nil, display_name: nil, slug: nil}

  # Keyed on RFC 7591 software_id. `engram-vault-sync` is our own plugin and is
  # the only proven-real entry. The other four are unvalidated guesses left in
  # place (harmless — real clients never send them) pending observation.
  @software_id %{
    "engram-vault-sync" => %{
      logo: "/assets/clients/engram-vault-sync.svg",
      display_name: "Obsidian Vault Sync",
      slug: nil
    },
    "anthropic-claude-desktop" => %{
      logo: "/assets/clients/claude.svg",
      display_name: "Claude Desktop",
      slug: "claude"
    },
    "cursor.sh" => %{logo: "/assets/clients/cursor.svg", display_name: "Cursor", slug: "cursor"},
    "openai-chatgpt" => %{
      logo: "/assets/clients/chatgpt.svg",
      display_name: "ChatGPT",
      slug: "chatgpt"
    },
    "vscode-engram" => %{
      logo: "/assets/clients/vscode.svg",
      display_name: "VS Code (Engram)",
      slug: nil
    }
  }

  # Keyed on redirect_uri host. Vendor-owned HTTPS hosts only.
  @redirect_host %{
    "claude.ai" => %{
      logo: "/assets/clients/claude.svg",
      display_name: "Claude",
      slug: "claude"
    }
  }

  @type entry :: %{
          verified: boolean(),
          logo: String.t() | nil,
          display_name: String.t() | nil,
          slug: String.t() | nil
        }

  @doc "Resolve identity from software_id first, then redirect host."
  @spec resolve(String.t() | nil, [String.t()] | nil) :: entry()
  def resolve(software_id, redirect_uris) do
    case lookup(software_id) do
      %{verified: true} = hit -> hit
      _ -> lookup_by_host(redirect_uris)
    end
  end

  @spec lookup(String.t() | nil) :: entry()
  def lookup(software_id) when is_binary(software_id) do
    case Map.get(@software_id, software_id) do
      nil -> @empty
      entry -> Map.merge(%{verified: true}, entry)
    end
  end

  def lookup(_), do: @empty

  # Only a vendor-owned HTTPS host with no userinfo grants verification. A
  # custom-scheme redirect (`com.evil.app://claude.ai/cb`) or `http://` host
  # parses to host "claude.ai" but delivers the auth code to an attacker-
  # controlled handler, so the un-spoofability argument does not hold — reject
  # both. Hosts are case-insensitive (RFC 3986 §3.2.2).
  defp lookup_by_host(uris) when is_list(uris) do
    Enum.find_value(uris, @empty, fn uri ->
      case URI.parse(uri) do
        %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
          case Map.get(@redirect_host, String.downcase(host)) do
            nil -> nil
            entry -> Map.merge(%{verified: true}, entry)
          end

        _ ->
          nil
      end
    end)
  end

  defp lookup_by_host(_), do: @empty
end
