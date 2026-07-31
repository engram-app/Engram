defmodule Engram.Connections.LogoAllowlist do
  @moduledoc """
  Identity metadata for OAuth clients, and the one rule for verifying them.

  ## Two independent questions

  **Who is this?** Three sources, in precedence order: the RFC 7591
  `software_id` (most MCP clients omit it), the `redirect_uri` host, and the
  normalized `client_name`.

  **Can we prove it?** Exactly one source: a vendor-owned HTTPS redirect host.
  That is un-spoofable for grant delivery: a forger can claim
  `redirect_uri=https://claude.ai/...`, but the auth code is then delivered to
  Anthropic, not to them.

  `software_id` and `client_name` both arrive inside the DCR request body, so
  they are things the client *says about itself*. Neither may grant
  `verified: true`; they supply identity only. (Tightened 2026-07-30:
  `software_id` previously granted the badge outright.)

  `software_id` no longer names any vendor either (2026-07-31). It used to carry
  four guessed vendor entries, so a rogue client registering
  `software_id: "anthropic-claude-desktop"` still appeared as **Claude Desktop**
  wearing Anthropic's logo — badge-less, but trustworthy-looking enough not to
  revoke. None of the nine connectors observed in prod sends the field at all,
  so the map was carrying attribution for nobody while remaining a free
  vendor-logo grant to anyone who read this source. The only surviving entry is
  our own plugin, which needs it: it redirects to a custom scheme and has
  nothing else to identify it.

  Loopback and custom schemes (Cursor desktop registers
  `cursor://anysphere.cursor-mcp/…`) never match the host map, so
  local-first clients are unverifiable by construction, not misconfigured.
  """

  @empty %{verified: false, logo: nil, display_name: nil, slug: nil}

  # Keyed on RFC 7591 software_id. OUR OWN PLUGIN ONLY.
  #
  # This map hands out a vendor logo and display name on a field the client
  # asserts about itself, so every entry is a spoofing surface: whatever
  # `software_id` you put here, anyone can register claiming it. Four guessed
  # vendor entries (`anthropic-claude-desktop`, `cursor.sh`, `openai-chatgpt`,
  # `vscode-engram`) were deleted on 2026-07-31 — none had ever been observed on
  # a real registration, and all nine connectors seen in prod omit the field
  # entirely, so they cost real users nothing and bought an attacker Anthropic's
  # icon.
  #
  # `engram-vault-sync` stays because it is ours and because it has no
  # alternative: it redirects to a custom scheme, which neither the host layer
  # nor name derivation can attribute.
  #
  # DO NOT add a vendor here to "improve attribution". A vendor that redirects to
  # its own HTTPS host belongs in @redirect_host, where the claim is provable; a
  # vendor that cannot is attributed by `client_name`, which grants slug only.
  @software_id %{
    "engram-vault-sync" => %{
      logo: "/assets/clients/engram-vault-sync.svg",
      display_name: "Obsidian Vault Sync",
      slug: nil
    }
  }

  # Keyed on redirect_uri host. Vendor-owned HTTPS hosts only. Every entry here
  # was observed on a real grant (prod, 2026-07-30). Do not add speculative
  # hosts; an entry that never fires is dead config that reads as coverage.
  # `logo: nil` where we have no asset yet; the UI falls back to a plug icon.
  @redirect_host %{
    "claude.ai" => %{
      logo: "/assets/clients/claude.svg",
      display_name: "Claude",
      slug: "claude"
    },
    "chatgpt.com" => %{
      logo: "/assets/clients/chatgpt.svg",
      display_name: "ChatGPT",
      slug: "chatgpt"
    },
    "grok.com" => %{logo: nil, display_name: "Grok", slug: "grok"},
    "callback.mistral.ai" => %{logo: nil, display_name: "Mistral", slug: "mistral"},
    # Antigravity registers as "antigravity-client", which does NOT derive to the
    # `antigravity` slug; the host is what carries it. Shared by Antigravity 2.0,
    # the IDE, and the CLI (one documented callback for all three).
    "antigravity.google" => %{logo: nil, display_name: "Antigravity", slug: "antigravity"}
  }

  # Slugs a client may self-report via `client_name`. `web_only` / `other_mcp`
  # are questionnaire answers, not products. No client may claim them.
  @derivable_slugs Engram.Onboarding.valid_tools() -- ~w(web_only other_mcp)

  # Normalized names that don't match their catalog slug. Keys are the exact
  # string `normalize_name/1` produces, so a `mcp_dcr_unattributed_client` Loki
  # line can be pasted straight in as a key.
  #
  # `visual_studio_code` is INFERRED, not observed: VS Code drives MCP OAuth
  # itself and registers under the product name, so a Copilot user's grant
  # arrives as "Visual Studio Code". The tripwire will confirm or refute it.
  @name_aliases %{"visual_studio_code" => "github_copilot"}

  @type entry :: %{
          verified: boolean(),
          logo: String.t() | nil,
          display_name: String.t() | nil,
          slug: String.t() | nil
        }

  @doc """
  Resolve a client's identity, and separately decide whether it is verified.

  **Identity** (logo / display_name / slug) comes from the first source that
  matches, **proven before claimed**: the redirect host, then `software_id`,
  then the normalized `client_name`.

  The host leads because it is the only source that is not self-asserted. A
  client claiming `software_id: "openai-chatgpt"` while redirecting to
  `claude.ai` must not be listed as ChatGPT: the grant is delivered to
  Anthropic, so Anthropic is who the user is actually connected to.

  **`verified`** is decided by exactly one thing: whether the redirect lands on
  a vendor-owned HTTPS host. Identity and verification are deliberately
  computed independently: `software_id` and `client_name` both arrive in the
  DCR body and are equally self-asserted, so neither may grant the badge.
  """
  @spec resolve(String.t() | nil, [String.t()] | nil, String.t() | nil) :: entry()
  def resolve(software_id, redirect_uris, client_name \\ nil) do
    by_host = lookup_by_host(redirect_uris)
    by_id = lookup(software_id)

    identity =
      cond do
        by_host != @empty -> by_host
        by_id != @empty -> by_id
        true -> lookup_by_name(client_name)
      end

    %{identity | verified: by_host != @empty}
  end

  # Slug-only attribution from the self-asserted `client_name`. UNVERIFIED BY
  # CONSTRUCTION: this path may set `slug` and nothing else.
  #
  # Why it exists: local-first clients (Claude Code, Cursor, Cline, …) redirect
  # to loopback, which is un-verifiable on purpose (see lookup_by_host/1). Until
  # this fallback they all resolved to `slug: nil`, so their onboarding
  # checklist row could never tick. A structural dead end for the whole class,
  # not a bug in any one connector.
  #
  # Rather than hand-feed a vendor map, we normalize the name back into slug
  # shape and accept it if the catalog already knows that slug. The catalog
  # slugs were coined from the product names, so this round-trips for
  # connectors we have never seen ("GitHub Copilot" -> github_copilot).
  #
  # The trailing-parenthetical strip is load-bearing: Claude Code registers as
  # "Claude Code (<mcp-server-name>)", where the suffix is whatever the user
  # named the server, so an exact match would miss every real installation.
  #
  # Spoofing this is not a security boundary; the worst outcome is a user
  # ticking a row in their own checklist. `verified` and `logo` stay gated on
  # software_id / vendor host, which is where the real spoofing risk lives.
  defp lookup_by_name(name) when is_binary(name) do
    case name |> normalize_name() |> then(&Map.get(@name_aliases, &1, &1)) do
      slug when slug in @derivable_slugs -> %{@empty | slug: slug}
      _ -> @empty
    end
  end

  defp lookup_by_name(_), do: @empty

  @doc """
  Folds a self-asserted `client_name` into slug shape: drops the trailing
  parenthetical, lowercases, and collapses punctuation to underscores.

  Public because the DCR tripwire logs this form: it is both the key you'd add
  to `@name_aliases` and, by dropping the parenthetical, free of the user-chosen
  server name that would otherwise land in Loki.
  """
  @spec normalize_name(String.t() | nil) :: String.t()
  def normalize_name(name) when is_binary(name) do
    name
    |> String.replace(~r/\s*\([^)]*\)\s*$/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  def normalize_name(_), do: ""

  @doc """
  Identity for a known `software_id`: logo, display_name, slug.

  Never sets `verified`: `software_id` is an RFC 7591 field the client sends
  about itself, so anyone can register claiming `anthropic-claude-desktop`.
  Granting the badge on it would let a rogue client wear a vendor's logo in the
  user's connections list. Only `resolve/3` decides verification, from the host.
  """
  @spec lookup(String.t() | nil) :: entry()
  def lookup(software_id) when is_binary(software_id) do
    case Map.get(@software_id, software_id) do
      nil -> @empty
      entry -> Map.merge(@empty, entry)
    end
  end

  def lookup(_), do: @empty

  # Only a vendor-owned HTTPS host with no userinfo grants verification. A
  # custom-scheme redirect (`com.evil.app://claude.ai/cb`) or `http://` host
  # parses to host "claude.ai" but delivers the auth code to an attacker-
  # controlled handler, so the un-spoofability argument does not hold, reject
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
