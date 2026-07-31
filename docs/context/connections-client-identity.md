Title: Connections client identity: slug attribution, the three hosting classes, and the HTTPS trust model

_Last verified: 2026-07-30 (rewritten fixing connector attribution for loopback + self-hosted clients; originally 2026-06-15)_

How `/settings/connections` cards and the onboarding checklist identify an OAuth/MCP client (logo, display_name, verified badge, checklist auto-check).

## The gotcha: `software_id` is almost never sent

`Engram.Connections.LogoAllowlist` originally keyed identity on the RFC 7591 `software_id`. That field is **optional and most MCP clients omit it**. Verified live against claude.ai's remote-MCP connector:

- `software_id: null`, `client_name: "Claude"`
- redirect `https://claude.ai/api/mcp/auth_callback`, UA `python-httpx`

So `lookup(nil)` never matched → generic `<Plug>` icon, "unverified" badge, no Claude mark, no checklist auto-check.

## Resolution order: `LogoAllowlist.resolve/3`

Identity resolves in `lib/engram/connections/logo_allowlist.ex`:

| Source | Grants | Why |
|---|---|---|
| `software_id` allowlist | `verified` + logo + slug | Explicit, but nearly nothing sends one |
| `redirect_uri` **host** allowlist | `verified` + logo + slug | A vendor-owned HTTPS host is un-spoofable for grant delivery |
| `client_name`, normalized | **slug only** | Self-asserted, so it may never grant `verified` or a logo |

`slug` then flows `Connections.list_for_user/1` → `ConnectionsController.serialize/1` → `/api/connections` → React (`connectedSlugs.has(slug)` ticks the checklist row; `ToolMark slug={...}` renders the brand mark).

## The three hosting classes

The load-bearing mental model. Connectors differ not by vendor but by **where the OAuth redirect lands**:

1. **Vendor-hosted**, `claude.ai`, `chatgpt.com`, `grok.com`, `callback.mistral.ai`. Fixed HTTPS host → allowlistable → `verified: true`.
2. **Local / loopback**, Claude Code, Cursor, Windsurf, Cline, Continue, OpenCode, GitHub Copilot. `http://localhost:<ephemeral>/callback`. **Un-verifiable by design.** Attribution must come from `client_name`.
3. **Self-hosted**: Open WebUI, LobeChat. Redirect host is *the operator's own domain* (observed: `https://ai.ras.band/oauth/clients/mcp:1/callback`). There is no vendor host to allowlist, not now, not ever. Also `client_name`-only.

Classes 2 and 3 are the majority of the catalog. **Any design keying attribution on the redirect host alone silently excludes both**. That was the 2026-07-30 bug.

## Trust model (security-relevant, do not weaken)

**Identity and verification are computed independently.** Identity (logo /
display_name / slug) comes from the first match of `software_id` → host → name.
`verified: true` is granted by **one thing only**: a vendor-owned **HTTPS**
redirect host, no userinfo, case-folded.

> **Tightened 2026-07-30.** `software_id` used to grant `verified: true`. It is
> an RFC 7591 field the client sends *about itself* in the DCR body, exactly as
> self-asserted as `client_name`, so anyone could register
> `software_id: "anthropic-claude-desktop"` and appear in a victim's connections
> list as a verified Claude Desktop, logo and all. Not an authorization-time
> phishing vector (the consent screen shows only `client_id` + `client_name`),
> but it made a rogue grant look trustworthy enough not to revoke. It now
> supplies identity only. Device-flow rows are unaffected, `device_rows/1`
> hardcodes `verified: true`, which is legitimate because our own server mints
> the `family_id`; no client-supplied metadata is involved.

- **Why HTTPS host is un-spoofable:** a forged DCR client can *claim* `redirect_uri=https://claude.ai/...`, but the auth code is then delivered to claude.ai, not to the attacker. The vendor controls the callback handler.
- **Why custom schemes / http are NOT:** `com.evil.app://claude.ai/cb` and `http://claude.ai/...` both parse to host `claude.ai` but deliver the code to an attacker-controlled handler. `lookup_by_host/1` enforces `%URI{scheme: "https", userinfo: nil}`. (Code review caught this; the naive host-only match was exploitable.)
- **`client_name` grants `slug` and nothing else.** It is self-asserted and trivially spoofable, but ticking a row in your *own* checklist is not a security boundary. The logo and the verified badge, where spoofing actually matters, stay host/`software_id` gated. `logo_allowlist_test.exs` pins this explicitly.

> **Correction (2026-07-30).** This doc previously said custom schemes and localhost were *"identify-only: they may set icon/name but never grant verified."* That was the intended design; the code never implemented it, `lookup_by_host/1` returned the empty placeholder, so loopback clients got **no slug at all** and their checklist row could never tick. The doc/code mismatch is why the gap survived six weeks. Slug attribution for those clients now comes from `client_name`.

## Observed registrations (prod, 2026-07-30)

Ground truth from real grants, not published docs:

| Connector | `client_name` | Redirect | Resolves via | Verified |
|---|---|---|---|---|
| Claude | (not recorded) | `https://claude.ai/api/mcp/auth_callback` | host | yes |
| ChatGPT | `ChatGPT` | `https://chatgpt.com/connector/oauth/<id>` | host | yes |
| Grok | `Grok` | `https://grok.com/connectors-oauth-exchange-code/` | host | yes |
| Mistral | `mistral-mcp-client` | `https://callback.mistral.ai/v1/integrations_auth/oauth2_callback` | host | yes |
| Antigravity | `antigravity-client` | `https://antigravity.google/oauth-callback` | host | yes |
| Claude Code | `Claude Code (<server>)` | `http://localhost:<port>/callback` | name | no |
| Open WebUI | `Open WebUI` | `https://<user-domain>/oauth/clients/mcp:1/callback` | name | no |
| Cline | `Cline` | `http://127.0.0.1:<port>/mcp/oauth/callback` | name | no |
| OpenCode | `OpenCode` | `http://127.0.0.1:<port>/mcp/oauth/callback` | name | no |

Mistral and Antigravity are the cases where **name** derivation fails
(`mistral_mcp_client` / `antigravity_client` are not catalog slugs) and the host
saves it. Claude Code, Open WebUI, Cline and OpenCode are the exact inverse.
Neither layer alone covers all nine, keep both.

> **Do not assume a client registers under its product name.** Three of nine
> observed clients append a suffix (`-client`, `(<server>)`). The name layer is a
> fallback for clients with no usable host, not a primary identifier.

**Cline and OpenCode are the predictions this design got to cash.** Both were
written into the test suite as *never-observed* connectors, asserting that
`"Cline" -> cline` and `"OpenCode" -> opencode` would derive from the catalog
with no new config. Both then registered for real within the hour and did
exactly that. That is the argument for normalizing names back into slug shape
rather than hand-maintaining a vendor map: the map only ever covers connectors
someone already noticed, and these two would have needed a code change each.

Note the shared `/mcp/oauth/callback` path: Cline and OpenCode register the same
loopback shape and differ only by `client_name` and port (both are also
Bun/TypeScript by user-agent, so a common MCP SDK OAuth client is the likely
cause, though we have not confirmed that). Either way it is a *family* of
connectors, not two coincidences, and it is exactly the family the host layer
can never attribute.

## Registration can reject a connector outright (two fixed 2026-07-30)

Attribution only matters once a client is *registered*. Two rules were turning
real connectors away at `/oauth/register`, which is a worse failure: no
`oauth_clients` row exists at all, so there is nothing to attribute, nothing in
the connections list, and no checklist row can ever tick.

**1. Public clients only.** `@valid_auth_methods` was `~w(none)`, so a
confidential registration was rejected. LobeHub cloud asks for one, and its
`connector.startOAuth` surfaced our `token_endpoint_auth_method: must be one of:
none` as its own 500. Note RFC 7591 §2 makes `client_secret_basic` the
**default** auth method: secret-based auth is the DCR baseline and `none` is the
opt-out, so we had implemented the MCP subset and treated it as the standard.
Now all three methods are accepted; a confidential registration mints a secret
(hashed into `client_secret_hash`, returned once) and the token endpoint
authenticates it.

**2. Reverse-DNS custom schemes only.** `check_uri/1` required a dot in a custom
scheme, citing RFC 8252 §7.1. Cursor desktop registers
`cursor://anysphere.cursor-mcp/oauth/callback` and was rejected; its log shows
the streamable-HTTP attempt failing on our error and the SSE fallback then
404/406-ing, which reads like a transport problem but is not. §7.1 obliges
*apps* to pick such a scheme; it does not ask servers to reject the ones that
don't. The dot never made a scheme exclusive on any OS either, so it reduced
accidental collisions, not squatting. **PKCE is the actual defence** and is
mandatory: an app that intercepts the redirect gets a code it cannot redeem.
`javascript:` / `data:` / `file:` are still rejected, and custom schemes remain
permanently unverifiable.

> **Cursor's published redirect URLs are not what it registers.**
> `cursor.com/docs/mcp` documents `https://www.cursor.com/agents/mcp/oauth/callback`
> and `http://localhost:8787/callback`. Those describe the *static OAuth* path
> where you pre-register URLs with a provider. Under DCR the desktop client
> sends `cursor://anysphere.cursor-mcp/oauth/callback`. Third case today where
> vendor docs disagreed with an observed registration; trust the row.

## Slug derivation is algorithmic, not a vendor map

The FTUX catalog slugs were coined from product names, so normalizing a `client_name` back into slug shape round-trips for connectors nobody has ever connected:

```
"GitHub Copilot"       -> github_copilot
"Open WebUI"           -> open_webui
"Claude Code (engram)" -> claude_code
```

`LogoAllowlist.normalize_name/1` = strip trailing parenthetical → downcase → collapse `[^a-z0-9]+` to `_` → trim `_`. Membership is checked against `Engram.Onboarding.valid_tools()` minus `web_only`/`other_mcp` (questionnaire answers, not products; no client may claim them).

The trailing-parenthetical strip is load-bearing: Claude Code registers as `Claude Code (<mcp-server-name>)` where the suffix is user-chosen, so an exact-match map entry misses every real installation.

## Learning a new connector without connecting it

A DCR registration whose `client_name` resolves to no slug logs `mcp_dcr_unattributed_client` (category `:lifecycle`, so it ships to Loki) carrying the **normalized** name. Paste that string straight into `@name_aliases`.

```logql
{app="engram"} |= "mcp_dcr_unattributed_client"
```

It logs the normalized form deliberately: that drops the user-chosen server suffix, so nothing personal reaches Loki.

Or read the DB directly:

```sql
SELECT software_id, client_name, redirect_uris FROM oauth_clients;
```

## Brand icons come from the slug, not the backend

`@lobehub/icons-static-svg` is already a dependency and already covers every catalog slug. Use `ToolMark slug={...}` (`frontend/src/onboarding/tool-icon.tsx`). The backend `logo: "/assets/clients/*.svg"` field is a legacy parallel system still needed only for `engram-vault-sync` and `vscode`; `grok.svg`/`mistral.svg` were never created and don't need to be.

## Known stale: the 4 guessed `software_id` entries

`anthropic-claude-desktop`, `cursor.sh`, `openai-chatgpt`, `vscode-engram` are UNVALIDATED guesses. Prod data now **proves** they never fire (the real ChatGPT and Claude grants both arrive with `software_id: null`). Harmless, but they read as coverage, do not add more speculative entries. The only proven-real `software_id` is our own `engram-vault-sync`.

`@name_aliases` currently carries one **inferred, not observed** entry: `visual_studio_code` → `github_copilot`. VS Code drives MCP OAuth itself, above the extension, so a Copilot user's grant is expected to arrive under the product name. The tripwire will confirm or refute it.

## Failed approaches / dead ends

- **Welding `slug` to `verified`.** Correct for logos, fatal for attribution, loopback can never verify, so ~7 of 14 catalog connectors could never tick. Decouple instead.
- **Exact-matching `client_name`.** Defeated by Claude Code's user-chosen parenthetical suffix.
- **Hand-maintaining a vendor name map.** Superseded by catalog derivation; the four dead `software_id` guesses are the cautionary tale.
- **Researching redirect URLs for the remaining connectors.** There is nothing to find. Vendors do not publish DCR `client_name`/`redirect_uri` values, and loopback/self-hosted clients have no fixed host by construction. Instrument, don't search.
- **Allowlisting a self-hosted instance's host.** Verifies exactly one operator and nobody else. Don't.

## Google: Antigravity yes, Gemini no (2026-07-30)

Google sunset **Gemini CLI** for AI Pro / Ultra / free tiers on **2026-06-18**
(also Gemini Code Assist IDE extensions), directing those users to **Antigravity
CLI**. Enterprise (Code Assist Standard/Enterprise, Google Cloud) and paid API
keys keep Gemini CLI, and the repo is still maintained, so it is a tier-scoped
sunset, not a deprecation.
([announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/))

Catalog decisions that follow:

- **`antigravity` is a real slug** (TOOL_CODING), attributed by the
  `antigravity.google` **host** entry, verified, with a logo. It registers as
  `antigravity-client`, so name derivation does *not* catch it; the initial
  assumption that it would was wrong and is pinned by a regression test.
- Antigravity connects to a DCR server with **nothing but a `serverUrl`**, the
  `oauth: {clientId, clientSecret}` block in its docs is only for servers without
  DCR, so our public-PKCE-only registration is fine. Config lives at
  `~/.gemini/config/mcp_config.json` (or workspace `.agents/mcp_config.json`);
  the key **must** be `serverUrl` (`url`/`httpUrl` are rejected). Auth is
  copy-paste-the-code via Agent Settings → Customizations → Authenticate, and
  MCP tools default to **Ask** mode until allowed with `mcp(engram/*)`.
- **`gemini` is deliberately NOT a selectable slug.** The consumer Gemini app has
  no UI for adding a custom remote MCP server. That is Gemini Enterprise (Cloud
  console → Data Stores → Custom MCP Server) or Antigravity. Making it
  selectable would manufacture an uncompletable checklist row, the same defect
  this whole doc is about.
- It is still **listed and greyed** in the FTUX picker via `ToolOption.unavailable`,
  because a silent absence reads as an Engram gap rather than a platform one. The
  slug is absent from `@valid_tools`, so it cannot reach a profile even if the UI
  is bypassed.
- **No `gemini_cli` slug.** Adding a product Google is retiring would be new dead
  config. If an enterprise Gemini CLI user connects, the tripwire logs it.

## The real fix for local clients: CIMD (not yet implemented)

**Client ID Metadata Documents** make the `client_id` an HTTPS URL owned by the
client vendor; the authorization server fetches it to obtain the client's
metadata. That URL's host is un-spoofable for the same reason a vendor redirect
host is: nobody else can serve a document at `claude.ai`. So CIMD gives us a
**provable identity for loopback clients**, which the redirect can never supply.

Status and why it matters:

- MCP `2025-11-25` adopted CIMD (IETF `draft-ietf-oauth-client-id-metadata-document`)
  and demoted DCR from SHOULD to **MAY**. The July 2026 spec update **deprecates
  DCR**, keeping it only for servers that haven't migrated. **We are on the
  deprecated path.**
- **Claude Code supports CIMD** (`oauth_cimd`). Anthropic's docs state Claude
  picks it only when the AS metadata advertises **both**:
  - `token_endpoint_auth_methods_supported` containing `"none"`, ✅ we already
    do (`well_known_controller.ex:66`)
  - `client_id_metadata_document_supported: true`, ❌ **we do not**
  With the flag missing, Claude Code falls back to DCR, which is exactly why the
  observed grant is an anonymous loopback client.
- Claude Desktop / Web / Cowork appear to use CIMD too, via shared infra.
- No MCP client sends an RFC 7591 `software_statement` (signed JWT), so that is
  not an alternative route to cryptographic vendor attribution today.

Implementing it means: advertise the flag, accept URL-shaped `client_id`s at
authorize/token, fetch + validate the document (HTTPS only, `application/json`,
its `client_id` must equal its own URL), cache with refresh, derive the redirect
allowlist from it, and guard the fetch against SSRF. Once shipped, Claude Code
grants become genuinely `verified` and the "recognized, self-reported" tier
below stops applying to them.

## "Why is Claude Code unverified? Am I connected wrong?"

No. Claude Code, and every local-first client, is unverifiable **by
construction**, not by misconfiguration. It redirects to
`http://localhost:<port>/callback`; anyone can claim a loopback URI, so it
asserts nothing about who the client is. RFC 8252 *recommends* loopback for
native apps precisely because it is the safest option for local software, but it
carries no identity proof. There is no setting that changes this.

The UI therefore shows **three** states, not two (`connections-page.tsx`):

| Condition | Chip | Meaning |
|---|---|---|
| `verified` | *(none)* | Redirect lands on a vendor-owned domain |
| `!verified` and `slug` | *(none)* | Recognized, but local/self-hosted, unprovable, and fine |
| `!verified` and no `slug` | `unverified` | Unrecognized client; check the redirect, consider revoking |

A recognized client is presented plainly, with its official brand mark: badging
Claude Code as suspect is simply wrong, and collapsing it into "unverified"
alongside genuinely unknown clients is what made users ask whether they had set
something up incorrectly. The chip is reserved for the case where it is
**actionable**. Provenance for all three states is spelled out in the expanded
row's `Identity:` line, so nothing is hidden. It just is not alarming.

## Other gotchas

- **`ai_connected` is dead.** Defined in `onboarding/action.ex` and `frontend/src/api/queries.ts`, written by nothing. Tool rows derive from live connections, not from that action.
- **`other_mcp` has no slug of its own.** No client resolves to it, so slug-matching left "Connect another MCP client" unstickable. Special-cased in `checklist-widget.tsx` to any live MCP grant not already claimed by another selected row.
- **`:auth` info logs do NOT reach Loki.** `Engram.Logger.Category.@info_to_loki` excludes `:auth`; the DCR tripwire uses `:lifecycle` for that reason.

## References

- `lib/engram/connections/logo_allowlist.ex`: resolution + normalization
- `lib/engram/connections.ex`: `list_for_user/1`, the only caller
- `lib/engram_web/controllers/oauth_register_controller.ex`: DCR + tripwire
- `frontend/src/onboarding/checklist-widget.tsx`: row completion
- `frontend/src/onboarding/tool-icon.tsx`: `ToolMark` / `ToolBadge`
- `frontend/src/onboarding/onboarding-tools.ts`: FTUX catalog (mirrors `Onboarding.valid_tools/0`)
- `docs/context/mcp-oauth.md`: the OAuth 2.1 + DCR flow itself
