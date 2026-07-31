Title: Connections client identity: slug attribution, the three hosting classes, and the HTTPS trust model

_Last verified: 2026-07-31 (CIMD shipped, #1148; guessed `software_id` entries deleted, #1156. Rewritten 2026-07-30 fixing connector attribution for loopback + self-hosted clients; originally 2026-06-15)_

How `/settings/connections` cards and the onboarding checklist identify an OAuth/MCP client (logo, display_name, verified badge, checklist auto-check).

## The gotcha: `software_id` is almost never sent

`Engram.Connections.LogoAllowlist` originally keyed identity on the RFC 7591 `software_id`. That field is **optional and most MCP clients omit it**. Verified live against claude.ai's remote-MCP connector:

- `software_id: null`, `client_name: "Claude"`
- redirect `https://claude.ai/api/mcp/auth_callback`, UA `python-httpx`

So `lookup(nil)` never matched → generic `<Plug>` icon, "unverified" badge, no Claude mark, no checklist auto-check.

## Resolution order: `LogoAllowlist.resolve/4`

Identity resolves in `lib/engram/connections/logo_allowlist.ex`:

Identity resolves **proven before claimed**, and `verified` is decided
separately from identity by the host alone:

| Precedence | Source | Grants | Why |
|---|---|---|---|
| 1 | **CIMD `client_id` host** | identity + `verified` | We fetched a metadata document from that host and it declared this exact `client_id`. The only proof available to a loopback client |
| 2 | `redirect_uri` **host** allowlist | identity + `verified` | A vendor-owned HTTPS host is un-spoofable for grant delivery |
| 3 | `software_id` allowlist | identity only | Self-asserted DCR body field. Since #1156 it contains ONLY our own plugin |
| 4 | `client_name`, normalized | **slug only** | Self-asserted, so it may never grant `verified` or a logo |

**CIMD verification does not require recognising the host.** Fetching the
document already established who serves it, so `verified: true` is granted for
any well-formed CIMD URL. `@redirect_host` is consulted only to *dress* the row
(logo, product name, catalog slug); an unrecognised vendor shows its host as the
display name and takes its checklist slug from `client_name`, the same mechanism
loopback clients already use.

> **The host outranks `software_id` (reversed during review, 2026-07-30).** It
> used to be the other way round, which meant a client registering
> `software_id: "openai-chatgpt"` while redirecting to `claude.ai` was listed as
> **ChatGPT** and carried a verified badge earned by Anthropic's host. If a
> grant is delivered to a vendor, that vendor is who the user is connected to;
> what the client *claims* cannot outrank it.

`slug` then flows `Connections.list_for_user/1` → `ConnectionsController.serialize/1` → `/api/connections` → React (`connectedSlugs.has(slug)` ticks the checklist row; `ToolMark slug={...}` renders the brand mark).

## The three hosting classes

The load-bearing mental model. Connectors differ not by vendor but by **where the OAuth redirect lands**:

1. **Vendor-hosted**, `claude.ai`, `chatgpt.com`, `grok.com`, `callback.mistral.ai`. Fixed HTTPS host → allowlistable → `verified: true`.
2. **Local / loopback**, Claude Code, Cursor, Windsurf, Cline, Continue, OpenCode, GitHub Copilot. `http://localhost:<ephemeral>/callback`. **Un-verifiable by design.** Attribution must come from `client_name`.
3. **Self-hosted**: Open WebUI, LobeChat. Redirect host is *the operator's own domain* (observed: `https://ai.ras.band/oauth/clients/mcp:1/callback`). There is no vendor host to allowlist, not now, not ever. Also `client_name`-only.

Classes 2 and 3 are the majority of the catalog. **Any design keying attribution on the redirect host alone silently excludes both**. That was the 2026-07-30 bug.

## Trust model (security-relevant, do not weaken)

**Identity and verification are computed independently.** Identity (logo /
display_name / slug) comes from the first match of CIMD host → redirect host →
`software_id` → name, **proven before claimed**. `verified: true` is granted by
**two** sources, and both are the same proof in different clothes — "this party
controls a host the vendor owns":

1. A vendor-owned **HTTPS redirect** host (no userinfo, case-folded).
2. A **CIMD `client_id`** URL whose document we fetched and which declared that
   same `client_id`.

Nothing else may ever grant it.

> **Tightened 2026-07-30.** `software_id` used to grant `verified: true`. It is
> an RFC 7591 field the client sends *about itself* in the DCR body, exactly as
> self-asserted as `client_name`, so anyone could register
> `software_id: "anthropic-claude-desktop"` and appear in a victim's connections
> list as a verified Claude Desktop, logo and all. Not an authorization-time
> phishing vector (the consent screen shows only `client_id` + `client_name`),
> but it made a rogue grant look trustworthy enough not to revoke. It now
> supplies identity only, and only when no vendor host outranks it.
>
> **Residue removed 2026-07-31 (#1156).** The tightening above left the rogue
> client with Claude's logo and display name; it only lost the badge. The four
> guessed `@software_id` entries were then deleted, so a self-asserted
> `software_id` now resolves to the unverified placeholder and grants **no
> vendor identity at all**. Only our own `engram-vault-sync` remains, and it
> needs the entry: it redirects to a custom scheme, so no host can attribute
> it, and its `client_name` derives no catalog slug.
>
> Device-flow rows are unaffected, `device_rows/1`
> hardcodes `verified: true`, which is legitimate because our own server mints
> the `family_id`; no client-supplied metadata is involved.

- **Why HTTPS host is un-spoofable:** a forged DCR client can *claim* `redirect_uri=https://claude.ai/...`, but the auth code is then delivered to claude.ai, not to the attacker. The vendor controls the callback handler.
- **Why custom schemes / http are NOT:** `com.evil.app://claude.ai/cb` and `http://claude.ai/...` both parse to host `claude.ai` but deliver the code to an attacker-controlled handler. `lookup_by_host/1` enforces `%URI{scheme: "https", userinfo: nil}`. (Code review caught this; the naive host-only match was exploitable.)
- **`client_name` grants `slug` and nothing else.** It is self-asserted and trivially spoofable, but ticking a row in your *own* checklist is not a security boundary. The logo and the verified badge, where spoofing actually matters, are host-gated only (since #1156 deleted the guessed `software_id` entries, no self-asserted field grants a vendor logo). `logo_allowlist_test.exs` pins this explicitly.
- **A proven host outranks a claimed `software_id`** (reversed during review, 2026-07-30). Previously `software_id` won, so a client claiming `openai-chatgpt` while redirecting to `claude.ai` was listed as ChatGPT *and* verified via Anthropic's host. Whoever receives the code is who the user is connected to.

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

## Loopback clients get a port exemption at authorize (RFC 8252 §7.3)

Registration is only half the path. A client that registers fine can still be
turned away at `/oauth/authorize`, and local-first clients were:

> RFC 8252 §7.3: "the authorization server **MUST** allow any port to be
> specified at the time of the request for loopback IP redirect URIs, to
> accommodate clients that obtain an available ephemeral port from the operating
> system at the time of the request."

`match_redirect_uri/2` did an exact `uri in client.redirect_uris`. That is
correct for every other class, and it is the first check still. But a DCR client
**registers once and persists its `client_id`**, then asks the OS for a fresh
ephemeral port on every launch. So the flow is: first run registers
`http://127.0.0.1:1456/...` and works, second run comes back on port 49152 and
gets `invalid_redirect_uri`.

This is why the observed ports look arbitrary (62184, 1456, 19876). **Never
treat an observed loopback port as stable, and never hardcode one.** The port is
the one component of a loopback redirect guaranteed to change.

The exemption is scoped hard:

| Component | Loopback `http` | Everything else |
|---|---|---|
| scheme | must be `http` | exact |
| host | exact (`localhost` ≠ `127.0.0.1`) | exact |
| **port** | **ignored** | exact |
| path, query | exact | exact |

It does **not** extend to `https`. Relaxing the port on `https://claude.ai`
would let anyone who controls any port on a registered host collect auth codes.
On loopback that argument does not hold the same way, since reaching the port
means already being on the user's machine, and PKCE still binds the code to the
request that started it.

`Engram.OAuth.Client.loopback_host?/1` is the single definition of "loopback",
shared by registration and authorization. If those two lists ever drifted apart,
a URI would be accepted at DCR and rejected on every authorize.

The token endpoint keeps exact matching (`check_code_redirect_uri/2`), and
should: it compares against the URI actually used at authorize, which was stored
on the code row, not against the registration.

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

## Deleted: the 4 guessed `software_id` entries (2026-07-31, #1156)

`anthropic-claude-desktop`, `cursor.sh`, `openai-chatgpt`, `vscode-engram` were UNVALIDATED guesses, and are now **gone**. Prod data proved they never fire (the real ChatGPT and Claude grants both arrive with `software_id: null`; Cursor registers `cursor://` with no `software_id`). They were not merely dead config, they were a free vendor-logo grant for anyone who read the source: registering `software_id: "anthropic-claude-desktop"` put Anthropic's logo and name on a rogue grant in the victim's connections list, with no `unverified` chip (the chip is suppressed whenever a slug resolves, deliberately, so Claude Code is not badged as suspect).

`engram-vault-sync` is the only remaining entry and the only proven-real one.

**Rule going forward: add a key here only for a `software_id` observed on a real registration.** A guess re-opens the impersonation. Check the `mcp_dcr_unattributed_client` tripwire for what clients actually send.

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

## The real fix for local clients: CIMD (SHIPPED 2026-07-31, #1148)

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
  - `token_endpoint_auth_methods_supported` containing `"none"`, ✅
  - `client_id_metadata_document_supported: true`, ✅ **advertised
    unconditionally** in `well_known_controller.ex`
- Claude Desktop / Web / Cowork appear to use CIMD too, via shared infra.
- No MCP client sends an RFC 7591 `software_statement` (signed JWT), so that is
  not an alternative route to cryptographic vendor attribution today.

### How it is built

`Engram.OAuth.Cimd` + `Engram.OAuth.Cimd.HttpFetcher` + `Engram.Http.SsrfGuard`.

- **DCR did not go away and will not.** Seven of the nine observed connectors do
  not use CIMD, and self-hosted clients never can (no vendor to publish a
  document). The two paths are independent: a CIMD client sends a URL-shaped
  `client_id` and never touches `/oauth/register`.
- **The PK was NOT widened.** `oauth_clients.client_id` stays a uuid; a unique
  partial-indexed `cimd_url` column carries the wire identity. `structure.sql`
  confirms `oauth_authorization_codes.client_id` and
  `oauth_refresh_tokens.client_id` are bare uuid columns with **no FK**, so
  nothing downstream needed touching.
- **THE binding is one line of validation:** the document's own `client_id` MUST
  equal the URL it was served from. Without it a vendor could serve a document
  claiming any client_id. Everything else the document says is then attributable
  to whoever controls that host, which is the point.
- **The `oauth_clients` row IS the document cache**, with `cimd_fetched_at` as
  its clock (24h TTL). No ETS cache: the redirect allowlist derives from the
  document and must be durable anyway, so a second copy would only add a way for
  the two to disagree.
- **A failed refresh keeps serving the stale row**, including when the *new*
  document fails validation. A vendor's five-minute outage must not lock out
  every user of that client.
- **Confidential auth methods in a document are refused, not downgraded.** A CIMD
  client never registered, so no secret exists: honouring it leaves the client
  unable to authenticate (nil hash), and downgrading to `none` makes it send a
  secret that `authenticate_client/2` must then reject for being present at all.
  Both failures are opaque; refusing the document is legible.
- **Document metadata is validated by `registration_changeset/2`**, not a parallel
  CIMD path, so the redirect-URI rules hardened in #1147 (the `https:///cb`
  host-less trap, array bounds, unsafe schemes) apply verbatim and cannot drift.

### The seam that was easy to get wrong

The wire `client_id` is a URL but `oauth_authorization_codes.client_id` and
`oauth_refresh_tokens.client_id` store the internal uuid. Three places compared
them with a bare `==` and would have rejected the *legitimate* client:
`check_code_client/2`, refresh rotation, and revocation. All three normalize
through `Engram.OAuth.internal_client_id/2`, which short-circuits when the wire id
already matches so the DCR path pays for no extra query.

`get_client/1` is a pure DB lookup. **Only `/oauth/authorize` may fetch a
document** — if token exchange or revocation could, a vendor outage would break
already-granted access.

### SSRF: most of the work (`Engram.Http.SsrfGuard`)

`/oauth/authorize` is unauthenticated, so this is an unauthenticated-request-
triggered outbound fetch: an SSRF primitive AND a traffic amplifier aimed at third
parties. There was no SSRF guard anywhere in `lib/` before this.

- https only, port 443 only, no userinfo, no fragment.
- Every resolved address checked against the IANA special-purpose ranges,
  including CGNAT `100.64/10`, link-local `169.254/16` (cloud metadata), IPv6
  ULA/link-local, and the v4-embedding transition ranges 6to4 `2002::/16` and
  Teredo `2001::/32` (a relay forwards those to an internal v4 host).
- IPv4-mapped IPv6 is unwrapped and judged as its inner v4 address:
  `::ffff:169.254.169.254` is the metadata service in a v6 costume.
- If **any** address for a name is non-public, the whole name is refused — a
  resolver answering with both a public and an internal address is either
  split-horizon or hostile and we cannot tell which.
- **Pinning**, the subtle one: the guard returns a URL with the host replaced by
  the address it validated, and the caller connects to *that* while passing the
  original hostname for SNI + certificate verification (Req's
  `connect_options: [hostname: ...]`). Handing the *hostname* to the HTTP client
  would re-resolve it, and the second answer is free to be `127.0.0.1` — DNS
  rebinding, where the check and the connection disagree.
- **Redirects are not followed.** A redirect is a new URL that would bypass the
  guard that approved the first one. A vendor that redirects its metadata document
  does not work, and that is the correct outcome.
- Body capped mid-stream at 64 KB.
- **Two rate-limit budgets, deliberately separate.** *Discovery* (a URL we have
  never seen) is the attacker-reachable path and is capped per-host (10/min) AND
  globally (60/min) — per-host alone does nothing against a caller varying the
  host, which is the amplification case. *Refresh* of an already-known client
  gets its own per-host bucket (10/min), because sharing one global budget would
  let an attacker cycling hosts starve refreshes for vendors real users are
  connected to, turning the anti-amplification control into a DoS vector against
  our own clients. Pinned by a test.

> **⚠ There is NO feature flag, deliberately.** An earlier revision gated this on
> `ENGRAM_CIMD_ENABLED` (default off) so the capability could be advertised
> staging-first. That was removed before merge: it was a knob that would be set to
> `true` once and never touched again, and a default-off flag nobody remembers to
> set is the worse failure — CIMD looks shipped, silently does nothing, and no
> tripwire fires because no CIMD traffic ever arrives.
>
> What that means operationally: **CIMD goes live the moment this deploys.** Claude
> Code stops choosing DCR as soon as it sees
> `client_id_metadata_document_supported`, and it does **not** fall back if our
> path is broken, so new Claude Code connections would fail rather than degrade.
> Existing DCR grants are separate rows and are unaffected either way. Backing it
> out is a revert of the advertisement line plus a deploy, not a config change.

**Tripwires:** `mcp_cimd_rejected` (a document was refused — reason + host, host
only because `:lifecycle` ships to Loki) and `mcp_cimd_stale_retained` (a refresh
failed and we are serving yesterday's document). Since there is no flag to blame,
these two are the first place to look if connectors start failing after a deploy.

## "Why is Claude Code unverified? Am I connected wrong?"

**Since CIMD shipped, it can be verified — but only if it publishes a document.**
A loopback *redirect* still proves nothing (anyone can claim a loopback URI), so
absent a CIMD document the answer below stands unchanged: unverifiable **by
construction**, not by misconfiguration, and no setting changes it. RFC 8252
recommends loopback for native apps because it is the safest option for local
software, not because it carries identity proof.

The UI shows **four** states (`connections-page.tsx`):

| Condition | Chip | `Identity:` row says |
|---|---|---|
| `verified` **and** `cimd_url` | *(none)* | "The app publishes its identity at a domain it owns" |
| `verified`, no `cimd_url` | *(none)* | "Sign-in redirects to a domain the vendor owns" |
| `!verified` and `slug` | *(none)* | "Self-reported. Local and self-hosted apps have no domain to check, so this is normal" |
| `!verified` and no `slug` | `unverified` | "Unrecognized client. Revoke it if you don't recognize the redirect below" |

**`verified` gates both "Verified." strings; `cimd_url` only chooses which proof
to name.** Branching on `cimd_url` alone would restate the backend's verification
rule in TypeScript with nothing keeping the two in sync, so loosening `SsrfGuard`
or `lookup_by_cimd` could have the UI assert a proof the server never granted.
The server stays the only thing that decides `verified`; a test pins the
unreachable-today `verified: false` + `cimd_url` combination.

**Keep the first two strings distinct.** They describe genuinely different proofs,
and collapsing them makes one of the two a lie: Claude Code over CIMD does *not*
"redirect to a domain the vendor owns" — it redirects to localhost. Both branches
are pinned by tests in `connections-page.test.tsx`.

The `Identifier:` row shows the `cimd_url` when there is one: it is the client's
real public identifier and, unlike an opaque uuid, the user can check it by
visiting it. `client_id` remains what the revoke button keys on.

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
