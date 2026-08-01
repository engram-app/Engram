defmodule Engram.Connections.LogoAllowlistTest do
  use ExUnit.Case, async: true
  alias Engram.Connections.LogoAllowlist

  test "known software_id returns identity but NOT verification" do
    result = LogoAllowlist.lookup("engram-vault-sync")
    assert %{verified: false, logo: "/assets/clients/engram-vault-sync.svg"} = result
  end

  # software_id arrives in the DCR body, it is a claim, not a proof. Since the
  # four guessed vendor entries were deleted (#1156) it buys no identity at
  # all, not merely no badge: a rogue registration gets the placeholder and the
  # "Unverified client" chip instead of Anthropic's logo and name.
  test "a self-asserted vendor software_id buys no identity at all" do
    assert %{verified: false, display_name: nil, logo: nil, slug: nil} =
             LogoAllowlist.resolve("anthropic-claude-desktop", ["http://localhost:1234/cb"])
  end

  # The other three deleted guesses, same rule. Named individually so a
  # re-added key fails here rather than silently restoring the logo grant.
  test "the deleted guessed software_ids resolve to the placeholder" do
    for id <- ~w(cursor.sh openai-chatgpt vscode-engram) do
      assert %{verified: false, display_name: nil, logo: nil, slug: nil} =
               LogoAllowlist.resolve(id, ["http://localhost:1234/cb"]),
             "#{id} must not grant vendor identity from a self-asserted claim"
    end
  end

  test "unknown software_id returns unverified placeholder" do
    assert %{verified: false, logo: nil} = LogoAllowlist.lookup("unknown-thing")
  end

  test "nil software_id returns unverified placeholder" do
    assert %{verified: false, logo: nil} = LogoAllowlist.lookup(nil)
  end

  test "resolve matches verified Claude by claude.ai redirect host" do
    result = LogoAllowlist.resolve(nil, ["https://claude.ai/api/mcp/auth_callback"])

    assert %{
             verified: true,
             slug: "claude",
             display_name: "Claude",
             logo: "/assets/clients/claude.svg"
           } = result
  end

  # REVERSED 2026-07-30 during review. This previously asserted that
  # `software_id` outranked the redirect host for identity, which is backwards:
  # software_id is a self-asserted DCR body field and the host is not. A client
  # claiming one vendor while its grant is delivered to another must be listed
  # as the vendor that actually receives the code.
  test "resolve prefers the redirect host over a self-asserted software_id" do
    result = LogoAllowlist.resolve("engram-vault-sync", ["https://claude.ai/x"])

    assert %{verified: true, slug: "claude", logo: "/assets/clients/claude.svg"} = result
  end

  # software_id still supplies identity when no vendor host is present, which is
  # the case it exists for: our own Obsidian plugin redirects to a custom
  # scheme, so nothing else can name it.
  test "resolve falls back to software_id when there is no vendor host" do
    result = LogoAllowlist.resolve("engram-vault-sync", ["obsidian://engram/cb"])

    assert %{verified: false, slug: nil, logo: "/assets/clients/engram-vault-sync.svg"} = result
  end

  test "resolve ignores loopback and custom-scheme redirects" do
    assert %{verified: false, logo: nil, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:51234/cb"])

    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, ["cursor://anyscheme"])
  end

  test "resolve does not verify a custom-scheme redirect pointing at a vendor host" do
    assert %{verified: false, slug: nil} =
             LogoAllowlist.resolve(nil, ["com.evil.app://claude.ai/callback"])
  end

  test "resolve does not verify a non-https redirect to a vendor host" do
    assert %{verified: false, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://claude.ai/api/mcp/auth_callback"])
  end

  test "resolve does not verify when vendor host is in userinfo, not the host" do
    assert %{verified: false, slug: nil} =
             LogoAllowlist.resolve(nil, ["https://claude.ai@evil.com/cb"])
  end

  test "resolve matches the vendor host case-insensitively" do
    assert %{verified: true, slug: "claude"} =
             LogoAllowlist.resolve(nil, ["https://CLAUDE.AI/api/mcp/auth_callback"])
  end

  test "resolve handles nil/empty redirect list" do
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, nil)
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, [])
  end

  test "lookup result carries slug key" do
    assert %{slug: nil} = LogoAllowlist.lookup("engram-vault-sync")
  end

  # --- Vendor redirect hosts observed in prod 2026-07-30 ---

  test "resolve verifies ChatGPT by chatgpt.com redirect host" do
    assert %{verified: true, slug: "chatgpt", display_name: "ChatGPT"} =
             LogoAllowlist.resolve(nil, ["https://chatgpt.com/connector/oauth/ig2N09X8ZQ6D"])
  end

  test "resolve verifies Grok by grok.com redirect host" do
    assert %{verified: true, slug: "grok", display_name: "Grok"} =
             LogoAllowlist.resolve(nil, ["https://grok.com/connectors-oauth-exchange-code/"])
  end

  test "resolve verifies Mistral by callback.mistral.ai redirect host" do
    assert %{verified: true, slug: "mistral", display_name: "Mistral"} =
             LogoAllowlist.resolve(nil, [
               "https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"
             ])
  end

  # --- client_name slug fallback: loopback clients that can never verify ---

  test "resolve derives a slug from Claude Code's parenthesized client_name" do
    assert %{slug: "claude_code"} =
             LogoAllowlist.resolve(
               nil,
               ["http://localhost:62184/callback"],
               "Claude Code (engram)"
             )
  end

  test "client_name slug survives an arbitrary user-chosen server suffix" do
    for name <- ["Claude Code (engram)", "Claude Code (notes)", "Claude Code", "claude code  "] do
      assert %{slug: "claude_code"} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], name),
             "expected #{inspect(name)} to resolve to claude_code"
    end
  end

  # THE load-bearing assertion: a self-asserted name is spoofable, so it may
  # only ever set `slug`. If this ever goes green with verified/logo set,
  # anyone can wear the Claude badge by naming their client "Claude".
  test "client_name grants slug only, never verified, never a logo" do
    assert %{verified: false, logo: nil, display_name: nil, slug: "claude_code"} =
             LogoAllowlist.resolve(nil, ["http://localhost:9/cb"], "Claude Code (evil)")
  end

  test "client_name cannot upgrade a spoofed vendor host to verified" do
    assert %{verified: false, logo: nil} =
             LogoAllowlist.resolve(nil, ["https://claude.ai@evil.com/cb"], "Claude Code (x)")
  end

  # Precedence is proven-over-claimed. software_id is a self-asserted DCR body
  # field; the vendor host is not. If a client claims one vendor and its grant
  # is delivered to another, the one we can PROVE must be what the user sees,
  # otherwise the connections list shows "ChatGPT" for a code Anthropic
  # received.
  # Uses `engram-vault-sync` because it is now the only software_id that
  # resolves to anything: with a deleted guess the assertion would pass on an
  # empty lookup and prove nothing about precedence.
  test "a verified host wins over a conflicting self-asserted software_id" do
    assert %{verified: true, slug: "claude", display_name: "Claude"} =
             LogoAllowlist.resolve(
               "engram-vault-sync",
               ["https://claude.ai/api/mcp/auth_callback"],
               nil
             )
  end

  test "a verified host match wins over client_name" do
    assert %{verified: true, slug: "claude", display_name: "Claude"} =
             LogoAllowlist.resolve(
               nil,
               ["https://claude.ai/api/mcp/auth_callback"],
               "Claude Code (engram)"
             )
  end

  # The catalog slugs were coined from the product names, so normalizing a
  # client_name back to slug shape round-trips for connectors we have never
  # observed. This is what makes the fallback general instead of a map we have
  # to hand-feed one vendor at a time.
  test "derives slugs for never-observed connectors from their product name" do
    for {name, slug} <- [
          {"Cursor", "cursor"},
          {"Windsurf", "windsurf"},
          {"GitHub Copilot", "github_copilot"},
          {"LobeChat", "lobechat"}
        ] do
      assert %{slug: ^slug} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], name),
             "expected #{inspect(name)} to derive slug #{inspect(slug)}"
    end
  end

  # Clients that have since registered for real, with their observed redirects.
  # Cline and OpenCode were both in the list above when it was written and moved
  # here within the hour: the derivation attributed two connectors nobody had
  # configured for, which is the whole case for normalizing over hand-feeding a
  # map. Note they share a redirect path and differ only by name, so they are a
  # family the host layer could never have told apart.
  #
  # All stay `verified: false`, and correctly. The loopback ones are unallowlist-
  # able by construction and Open WebUI redirects to the operator's own domain,
  # so none is provable. Unverified means "unprovable", not "suspect".
  test "attributes observed name-only connectors (Cline, OpenCode, Open WebUI)" do
    assert %{slug: "cline", verified: false} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:1456/mcp/oauth/callback"], "Cline")

    assert %{slug: "opencode", verified: false} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:19876/mcp/oauth/callback"], "OpenCode")

    assert %{slug: "open_webui", verified: false} =
             LogoAllowlist.resolve(
               nil,
               ["https://ai.ras.band/oauth/clients/mcp:1/callback"],
               "Open WebUI"
             )
  end

  # Observed 2026-07-30. Antigravity is the counter-example to name derivation:
  # it registers as "antigravity-client", which normalizes to `antigravity_client`
  # and matches no slug. The vendor host is what attributes it, and because the
  # host is vendor-owned, it also earns `verified`.
  test "resolve verifies Antigravity by its vendor host, not its client_name" do
    assert %{verified: true, slug: "antigravity", display_name: "Antigravity"} =
             LogoAllowlist.resolve(
               nil,
               ["https://antigravity.google/oauth-callback"],
               "antigravity-client"
             )

    # Prove the name alone would NOT have carried it.
    assert %{slug: nil} =
             LogoAllowlist.resolve(nil, ["http://localhost:1/cb"], "antigravity-client")
  end

  # Observed 2026-08-01 on staging, both previously rendering as "Unrecognized
  # client". Devin has no catalog slug: `Engram.Onboarding.valid_tools/0` has no
  # `devin`, and adding one needs a /docs/integrations/devin/ page first
  # (checklist-widget's #1157 parity test). Attribution and the badge do not
  # depend on the slug, so the entry stands on its own.
  test "resolve verifies Devin by its vendor host, with no catalog slug" do
    assert %{verified: true, display_name: "Devin", slug: nil} =
             LogoAllowlist.resolve(
               nil,
               ["https://api.devin.ai/mcp/oauth/callback"],
               "Devin"
             )
  end

  # LobeHub is the cloud host, LobeChat the product and the catalog slug — so
  # this host ticks an onboarding row that already exists. The observed
  # client_name is "LobeHub", which does NOT derive to `lobechat`, so the host
  # map is what carries the mapping.
  test "resolve verifies LobeHub by its vendor host and maps it to the lobechat slug" do
    assert %{verified: true, display_name: "LobeChat", slug: "lobechat"} =
             LogoAllowlist.resolve(
               nil,
               ["https://app.lobehub.com/oauth/connector/callback"],
               "LobeHub"
             )

    # Prove the name alone would NOT have carried the slug.
    assert %{slug: nil, verified: false} =
             LogoAllowlist.resolve(nil, ["http://localhost:1/cb"], "LobeHub")
  end

  # Self-hosted LobeChat redirects to the operator's own domain, so it must stay
  # unverified — the cloud entry above must not leak the badge to every install.
  test "self-hosted LobeChat on an operator domain stays unverified" do
    assert %{verified: false} =
             LogoAllowlist.resolve(
               nil,
               ["https://lobe.mycompany.example/oauth/connector/callback"],
               "LobeHub"
             )
  end

  # Self-hosted clients redirect to the operator's OWN domain, so there is no
  # vendor host to allowlist, ever. Observed in prod 2026-07-30: Open WebUI
  # arriving from a user-run instance. It must still earn its slug (via name)
  # while staying unverified (the host proves nothing about who built it).
  test "a self-hosted client gets its slug by name but is never verified by its own host" do
    assert %{verified: false, logo: nil, slug: "open_webui"} =
             LogoAllowlist.resolve(
               nil,
               ["https://ai.ras.band/oauth/clients/mcp:1/callback"],
               "Open WebUI"
             )
  end

  # `web_only` and `other_mcp` are questionnaire answers, not products. A client
  # claiming to be one would tick a row it has no business ticking.
  test "never derives the non-product catalog answers from a client_name" do
    assert %{slug: nil} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "web only")
    assert %{slug: nil} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "Other MCP")
  end

  test "client_name normalization tolerates punctuation and empty residue" do
    assert %{slug: "github_copilot"} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "GitHub-Copilot")

    assert %{slug: nil} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "***")
    assert %{slug: nil} = LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "")
  end

  test "unknown or nil client_name stays empty" do
    assert %{verified: false, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://localhost:1/cb"], "Some Random Client")

    assert %{verified: false, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://localhost:1/cb"], nil)
  end

  # --- CIMD: the only proof a loopback client can ever offer ---

  # THE case CIMD exists for. Claude Code redirects to loopback, so the redirect
  # layer can never verify it. The CIMD client_id can, because we fetched a
  # document from that host and it declared this exact client_id.
  test "a CIMD client_id verifies a client whose redirect is loopback" do
    assert %{verified: true, slug: "claude", display_name: "Claude"} =
             LogoAllowlist.resolve(
               nil,
               ["http://127.0.0.1:51234/callback"],
               "Claude Code (engram)",
               "https://claude.ai/.well-known/oauth-client"
             )
  end

  # Verification does not depend on RECOGNISING the host: fetching the document
  # already proved who serves it. The allowlist only dresses the row for vendors
  # we happen to know.
  test "an unrecognised CIMD host is still verified, and shows its host" do
    assert %{verified: true, display_name: "newvendor.example", logo: nil} =
             LogoAllowlist.resolve(
               nil,
               ["http://127.0.0.1:1/cb"],
               nil,
               "https://newvendor.example/client"
             )
  end

  # An unrecognised CIMD vendor still earns its checklist row via the same
  # name derivation loopback clients already use.
  test "an unrecognised CIMD host takes its slug from client_name" do
    assert %{verified: true, slug: "cline"} =
             LogoAllowlist.resolve(
               nil,
               ["http://127.0.0.1:1/cb"],
               "Cline",
               "https://cline.example/client"
             )
  end

  test "CIMD identity outranks a conflicting redirect host" do
    assert %{verified: true, slug: "claude", display_name: "Claude"} =
             LogoAllowlist.resolve(
               nil,
               ["https://chatgpt.com/connector/oauth/x"],
               nil,
               "https://claude.ai/.well-known/oauth-client"
             )
  end

  # Defensive: a cimd_url is only ever written by Engram.OAuth.Cimd, which fetched
  # it through the SSRF guard (https, no userinfo). If a malformed one ever reached
  # this row, it must not be treated as proof of anything.
  test "a malformed cimd_url grants no verification" do
    for url <- [
          "http://claude.ai/client",
          "https://claude.ai@evil.example/client",
          "https:///client",
          "not a url",
          ""
        ] do
      assert %{verified: false} =
               LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], nil, url),
             "#{inspect(url)} must not verify"
    end
  end

  test "a nil cimd_url leaves existing behaviour untouched" do
    assert %{verified: true, slug: "claude"} =
             LogoAllowlist.resolve(nil, ["https://claude.ai/cb"], nil, nil)

    assert %{verified: false, slug: "cline"} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:1/cb"], "Cline", nil)
  end
end
