# Connection identity via redirect host — design

**Date:** 2026-06-15
**Status:** Approved, pre-implementation
**Scope:** Make the Claude connection render its brand identity correctly on
`/settings/connections` and auto-check its onboarding-checklist row. Build the
matcher so other clients (ChatGPT, Cursor, …) drop in later, but only ship +
prove **Claude** now.

## Problem

`Engram.Connections.LogoAllowlist` maps a trusted `software_id` →
`{logo, display_name, verified}`. The connector card and (future) checklist
both depend on that lookup.

`software_id` (RFC 7591) is **optional and usually omitted**. Verified against a
live production grant:

```json
{"kind":"mcp","name":"Claude","software_id":null,"verified":false,"logo":null,
 "redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}
```

claude.ai's remote-MCP connector sends `software_id: null`, so
`LogoAllowlist.lookup(nil)` returns the unverified placeholder. Result on the
card: generic `<Plug>` icon, an "unverified" badge, and the bare DCR-asserted
name "Claude" — no Claude mark.

The allowlist's Claude key (`anthropic-claude-desktop`) and the other three
entries (`cursor.sh`, `openai-chatgpt`, `vscode-engram`) are unvalidated
guesses. The only proven-real `software_id` is our own `engram-vault-sync`
plugin.

## Root cause

Wrong discriminator. The stable, observable identifier an MCP client always
supplies is the `redirect_uri`, not `software_id`. Vendors publish exact
callbacks and OAuth enforces a character-for-character match, so it can't drift
silently:

| Client | Published callback | Trust |
|--------|-------------------|-------|
| Claude | `https://claude.ai/api/mcp/auth_callback` | vendor HTTPS host — high |
| ChatGPT | `https://chatgpt.com/connector_platform_oauth_redirect` | vendor HTTPS host — high |
| Cursor | `cursor://` (native scheme) | spoofable — identify only |
| VS Code | `vscode://` / `vscode.dev` / localhost | spoofable — identify only |

(Sources: Qlik MCP admin guide 2026-03; Obsidian Security "When MCP Meets
OAuth" 2026-02. ChatGPT/Cursor/VS Code rows are not yet validated against our
own data and are out of scope for this change.)

### Trust model

A fake DCR client can *claim* `redirect_uri = https://claude.ai/...`, but the
authorization code is then delivered to claude.ai, not to the attacker — so a
vendor-owned **HTTPS** host is effectively un-spoofable and may grant
`verified: true`. Custom schemes (`cursor://`) and `localhost` are usable by
any local process → they may drive the icon/name but must NOT grant `verified`.

## Approach

Resolve identity from `(software_id, redirect_uris)`:

1. Try the existing `software_id` allowlist first — preserves `engram-vault-sync`.
2. Fall back to a **redirect-host allowlist**. Claude's null `software_id` falls
   through to a `claude.ai` host match.

Only `claude.ai` is added this round. The four guessed `software_id` entries are
left untouched (harmless — they never match a real client) and flagged stale;
they'll be revisited when those clients are actually connected and observed.

## Components

### Backend — `Engram.Connections.LogoAllowlist`

- Add `slug` to every identity result. Shape becomes
  `%{verified, logo, display_name, slug}`.
- Add a redirect-host map: `"claude.ai" => %{slug: "claude",
  display_name: "Claude", logo: "/assets/clients/claude.svg", verified: true}`.
- New `resolve(software_id, redirect_uris)`:
  - `software_id` hit → that entry (verified).
  - else first `redirect_uri` whose host is in the host map → that entry.
  - else `%{verified: false, logo: nil, display_name: nil, slug: nil}`.
- Host extraction uses `URI.parse/1`; only the host is matched (path ignored).
  Non-HTTPS / scheme-only redirects (e.g. `cursor://`) never match the host map.

### Backend — `Engram.Connections.oauth_rows/1`

- Call `resolve(c.software_id, c.redirect_uris)` instead of
  `lookup(c.software_id)`.
- Add `slug: identity.slug` to the connection view map.

### Backend — `ConnectionsController.serialize/1`

- Add `slug: row.slug` to the JSON payload. Device/PAT rows serialize `slug: nil`.

### Frontend — connector card (`connections-page.tsx`)

No change. It already renders backend `logo` / `verified` / `name`. Once the
backend resolves claude.ai, the card shows `claude.svg`, drops "unverified", and
keeps name "Claude".

### Frontend — checklist (`checklist-widget.tsx`)

- `Connection` type gains `slug?: string | null`.
- `useConnections` is currently gated on `profile?.uses_obsidian`; un-gate it so
  MCP grants are always loaded.
- Build `connectedSlugs = new Set(connections.filter(c => c.kind === 'mcp')
  .map(c => c.slug).filter(Boolean))`.
- A tool row's `done` becomes `isDismissed(slug) || connectedSlugs.has(slug)`.
- No per-row brand icon (rejected as too busy). The box simply checks off /
  the row drops from `visible` when a matching connection exists.

## Data flow

```
oauth_clients row ─► resolve(software_id, redirect_uris)
                       ├─ software_id hit ─► identity (engram-vault-sync)
                       └─ host(redirect_uri) ∈ host map ─► identity (claude)
                     ─► connection view {..., slug, logo, verified, name}
                     ─► GET /api/connections JSON
        card ─────────► logo img + name + (no) unverified badge
        checklist ────► connectedSlugs.has(slug) → row done
```

## Error / edge handling

- `redirect_uris` nil or `[]` → no host match → unverified placeholder (current
  behavior preserved).
- Malformed redirect URI → `URI.parse` yields `host: nil` → skipped, no crash.
- Multiple redirect URIs → first host that matches wins.
- A connection we can't identify keeps the generic card and a manually-dismissable
  checklist row (unchanged).

## Testing (TDD)

- `logo_allowlist_test.exs`: redirect host `claude.ai` → verified Claude identity
  with slug; `software_id` path still resolves `engram-vault-sync`; unknown host
  and `cursor://` scheme → unverified nil; nil/empty redirects → unverified nil.
- `connections_test.exs`: oauth row with `software_id: nil` +
  `["https://claude.ai/api/mcp/auth_callback"]` → name "Claude", verified true,
  logo set, slug "claude".
- `connections_controller_test.exs`: serialized payload includes `slug`.
- `checklist-widget.test.tsx`: a tool row auto-clears when a matching-slug MCP
  connection exists; remains (dismissable) when none.

## Proof of done

Backend unit tests green, then reload `/settings/connections` in the browser:
the Claude card shows the Claude mark + drops "unverified", and the "Connect
Claude" checklist row disappears (the live claude.ai grant satisfies it).

## Out of scope

- Validating / fixing the four guessed `software_id` entries.
- ChatGPT / Cursor / VS Code redirect-host entries (added when observed).
- Per-row brand icons in the checklist.

## Delivery

Single PR in the engram repo (backend + `backend/frontend` live together).
