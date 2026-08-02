defmodule Engram.Connections.LogoAllowlist do
  @moduledoc """
  Identity metadata for OAuth clients, and the one rule for verifying them.

  ## Two independent questions

  **Who is this?** Four sources, in precedence order: the CIMD `client_id` host,
  the `redirect_uri` host, the RFC 7591 `software_id` (which now names only our
  own plugin), and the normalized `client_name`.

  **Can we prove it?** Two sources, and both are the same proof in different
  clothes — "this party controls a host the vendor owns":

    * A vendor-owned HTTPS **redirect** host. A forger can claim
      `redirect_uri=https://claude.ai/...`, but the auth code is then delivered
      to Anthropic, not to them.
    * A **CIMD** `client_id` URL. We fetched a metadata document from that exact
      host and it declared the same `client_id`; nobody but Anthropic can serve a
      document at `claude.ai`.

  CIMD is the one that reaches local-first clients. Claude Code, Cline, Cursor
  and OpenCode all redirect to loopback, so the redirect can never prove anything
  about them — see `Engram.OAuth.Cimd`.

  `software_id` and `client_name` both arrive inside the DCR request body, so
  they are things the client *says about itself*. Neither may grant
  `verified: true`; they supply identity only. (Tightened 2026-07-30:
  `software_id` previously granted the badge outright.)

  As of 2026-07-31 a self-asserted `software_id` buys **no vendor identity at
  all**. The four guessed entries that previously handed out Claude's, Cursor's,
  ChatGPT's and VS Code's logos were deleted, leaving only our own
  `engram-vault-sync` plugin. A rogue client registering
  `software_id: "anthropic-claude-desktop"` now resolves to the unverified
  placeholder and renders with the "Unverified client" chip, rather than
  appearing in the victim's connections list wearing Anthropic's logo.

  This closed the last gap where a claim, not a proof, drove what the user sees.
  The security boundary is still `verified`; this removed the cosmetic
  trustworthiness that made a rogue grant look not worth revoking.

  Loopback and custom schemes (Cursor desktop registers
  `cursor://anysphere.cursor-mcp/…`) never match the host map, so
  local-first clients are unverifiable by construction, not misconfigured.
  """

  @empty %{verified: false, logo: nil, display_name: nil, slug: nil}

  # Keyed on RFC 7591 software_id. Entries here must be OBSERVED on a real
  # registration, never guessed: this map is the one place a self-asserted
  # string still buys a vendor's logo, so every speculative key is a free
  # impersonation for anyone who reads the source.
  #
  # `engram-vault-sync` is our own plugin, and it needs the entry: it redirects
  # to a custom scheme, so the host map can never attribute it, and its
  # `client_name` does not derive to a catalog slug.
  #
  # Four guessed entries (`anthropic-claude-desktop`, `cursor.sh`,
  # `openai-chatgpt`, `vscode-engram`) were deleted 2026-07-31. None was ever
  # observed in prod; all nine real connectors are attributed by redirect host
  # or `client_name`, and Cursor in fact registers `cursor://` with no
  # software_id at all.
  @software_id %{
    "engram-vault-sync" => %{
      logo: "/assets/clients/engram-vault-sync.svg",
      display_name: "Obsidian Vault Sync",
      slug: nil
    }
  }

  # Keyed on redirect_uri host. Vendor-owned HTTPS hosts only. Every entry here
  # was observed on a real grant — the first five in prod on 2026-07-30, Devin
  # and LobeHub on staging on 2026-08-01. Staging counts because what the rule
  # is actually guarding is "a real client really redirected here", not which
  # environment answered; a guessed host is the thing that must never land. Do
  # not add speculative hosts; an entry that never fires is dead config that
  # reads as coverage.
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
    "antigravity.google" => %{logo: nil, display_name: "Antigravity", slug: "antigravity"},
    # Devin registers `client_name: "Devin"`, which does not derive to a catalog
    # slug because there is no `devin` tool in `Engram.Onboarding.valid_tools/0`
    # — so `slug: nil` and it gets no checklist row. Adding one would need a
    # `/docs/integrations/devin/` page first: `checklist-widget.tsx` has a parity
    # test (#1157) requiring every selectable slug to carry its own doc URL, and
    # that page currently 404s. Attribution and the verified badge do not depend
    # on the slug, so this entry is useful on its own.
    "api.devin.ai" => %{logo: nil, display_name: "Devin", slug: nil},
    # LobeHub is the cloud host; LobeChat is the product and the catalog slug, so
    # the row already exists in onboarding and this host ticks it. The observed
    # `client_name` is "LobeHub", which is why the host map has to carry the
    # mapping — the name does not derive to `lobechat`.
    "app.lobehub.com" => %{logo: nil, display_name: "LobeChat", slug: "lobechat"}
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
  matches, **proven before claimed**: the CIMD `client_id` host, then the
  redirect host, then `software_id`, then the normalized `client_name`.

  The two host sources lead because they are the only ones that are not
  self-asserted. A client claiming `software_id: "engram-vault-sync"` while
  redirecting to `claude.ai` must not be listed as our plugin: the grant is
  delivered to Anthropic, so Anthropic is who the user is actually connected to.

  **`verified`** is decided by two sources, and by nothing else:

    * the redirect landing on a vendor-owned HTTPS host, or
    * a CIMD `client_id` whose metadata document we fetched from that host.

  Both are the same argument — "this party controls a host the vendor owns" —
  and CIMD is the one that reaches loopback clients, which no redirect can
  prove. Note that CIMD grants the badge **without** the host having to appear
  in `@redirect_host`: fetching the document already established who serves it.

  Identity and verification are deliberately computed independently, because
  `software_id` and `client_name` both arrive in the DCR body and are equally
  self-asserted, so neither may ever grant the badge.
  """
  @spec resolve(String.t() | nil, [String.t()] | nil, String.t() | nil, String.t() | nil) ::
          entry()
  def resolve(software_id, redirect_uris, client_name \\ nil, cimd_url \\ nil) do
    by_cimd = lookup_by_cimd(cimd_url)
    by_host = lookup_by_host(redirect_uris)
    by_id = lookup(software_id)

    identity =
      cond do
        by_cimd != @empty -> fill_slug(by_cimd, client_name)
        by_host != @empty -> by_host
        by_id != @empty -> by_id
        true -> lookup_by_name(client_name)
      end

    %{identity | verified: by_cimd != @empty or by_host != @empty}
  end

  # A CIMD vendor we have no `@redirect_host` entry for still deserves its
  # checklist row, and the name-derived slug is exactly the mechanism loopback
  # clients already use. Safe for the same reason it is safe there: a slug ticks a
  # row in the user's own checklist and grants neither logo nor badge. A CIMD
  # client has *more* standing than a loopback one, not less.
  defp fill_slug(%{slug: nil} = identity, client_name),
    do: %{identity | slug: lookup_by_name(client_name).slug}

  defp fill_slug(identity, _client_name), do: identity

  # A CIMD `client_id` is an HTTPS URL whose document we fetched from that exact
  # host, and the document's own `client_id` had to equal the URL. So the host
  # owner authored this client, by the same argument that makes a vendor redirect
  # host un-spoofable — and unlike the redirect, it works for loopback clients,
  # which is the entire reason CIMD is worth implementing.
  #
  # Verification therefore does NOT depend on recognising the host: fetching the
  # document already proved who serves it. `@redirect_host` is consulted only to
  # dress the row (logo, product name, catalog slug) for vendors we know.
  defp lookup_by_cimd(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        @empty
        |> Map.merge(Map.get(@redirect_host, String.downcase(host), %{}))
        |> Map.put(:verified, true)
        |> put_host_display_name(host)

      _ ->
        @empty
    end
  end

  defp lookup_by_cimd(_), do: @empty

  # An unrecognised CIMD vendor shows its host as the display name. The host is
  # proven (that is what fetching the document established), so this is honest,
  # and it beats a blank name on a row the UI is about to call verified.
  defp put_host_display_name(%{display_name: nil} = identity, host),
    do: %{identity | display_name: host}

  defp put_host_display_name(identity, _host), do: identity

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
  about itself, so anyone can register claiming to be anyone. Only `resolve/3`
  decides verification, from the host.

  The map is deliberately down to our own plugin, so an unrecognized claim
  returns the placeholder rather than a vendor's logo. Adding a key here on a
  guess re-opens that impersonation; add one only for an id observed on a real
  registration.
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
