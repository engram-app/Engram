# Refresh token rotation — reuse detection + leeway (as-built)

_Last verified: 2026-06-18_

_Status: SHIPPED 2026-05-28 (Engram PR #341), v0.5.245. Backend repo (`engram`).
Both halves landed: the leeway/overlap window AND token-family reuse-detection
revocation. This doc describes the as-built behavior; the old "build plan"
sections were folded into "As built" below._

## Why

Device refresh tokens (`DeviceFlow`) are single-use rotating, 90-day TTL, 15-min
access tokens. The Obsidian plugin previously held only the access token in
memory, so every reload forced a refresh that rotated the single-use token; a
lost rotation save (BRAT reload mid-refresh, etc.) bricked the session → forced
re-login. Two fixes:

- **Plugin (Engram-obsidian PR #84, shipped):** persist the access token so
  reloads within its 15-min life skip the refresh entirely (no rotation).
- **Backend (this plan):** make rotation robust + secure per RFC 9700.

## Research verdict (RFC 9700 §4.14.2 + Auth0/Okta docs)

Best practice for public clients without sender-constrained tokens is **refresh
token rotation + reuse detection with token-family revocation**, layered with a
**short leeway/overlap window** for benign retries/concurrency:

- On reuse of an *already-invalidated* token **outside** the leeway → breach →
  **revoke the entire token family** → force re-login. (RFC 9700 MUST; Auth0
  "Automatic Reuse Detection"; Okta "grace period".)
- **Within** the leeway window, accept the immediately-previous token, issue a
  new one, skip breach detection. (Auth0 `leeway` / "Rotation Overlap Period";
  default 0, "shortest amount of time" recommended.)

PR #341 shipped **both** halves: the leeway/overlap window and family-wide
reuse-detection revocation.

Sources: RFC 9700 §4.14.2 (ietf.org/rfc/rfc9700.html); Auth0 "Refresh Token
Rotation" + "Configure Refresh Token Rotation" (`leeway` attr); WorkOS "We read
RFC 9700".

## As built

- **Schema** — `Engram.Auth.DeviceRefreshToken` has a `family_id :uuid` column
  (`device_refresh_token.ex:8`), required in the changeset. Each existing row was
  backfilled with its own fresh family.
- **`create_refresh_token/3`** (`device_flow.ex:257`) takes an optional
  `family_id`; `nil` mints a fresh uuid (new login), rotation inherits the old
  token's `family_id` to keep the lineage together.
- **`refresh_access_token/1`** (`device_flow.ex:144`) looks up by hash where
  `expires_at > now` (regardless of `revoked_at`), then:
  - not found → `{:error, :invalid_refresh_token}`
  - active (`revoked_at` nil) → rotate: stamp `revoked_at`, issue child in same
    family.
  - revoked **within** leeway → benign retry: `issue_child` in same family, no
    re-revocation.
  - revoked **outside** leeway (or older token) → **reuse breach**:
    `invalidate_family/1` runs `delete_all where family_id == ^fid`
    (`device_flow.ex:251`) and returns `{:error, :invalid_refresh_token}`. It
    **deletes** rather than `update_all` set `revoked_at` — a freshly-revoked
    current token would otherwise land *inside* the leeway and be misclassified
    as benign on next presentation. A `Logger.warning` records the breach
    (`family_id` + `user_id`) so the audit trail survives row deletion.
- **Leeway policy** — extracted into `Engram.Auth.RefreshLeeway` (`@seconds 30`,
  boundary-inclusive `benign?/2`). The old `@refresh_grace_seconds 60` is gone.
- **Tests** — `test/engram/auth/device_flow_test.exs` +
  `test/engram_web/controllers/device_auth_controller_test.exs` cover: normal
  rotation chain, reuse within leeway → ok, **reuse outside leeway → whole family
  revoked (the current valid token also rejected)**, the leeway boundary,
  expired-AND-revoked rejected, unknown token → invalid.

## Notes / gotchas

- `skip_tenant_check: true` is fine here — lookup is keyed on the 256-bit
  `token_hash`; issued tokens inherit `old_token.user_id`/`vault_id`, so a token
  can only mint tokens for its own owner. Family invalidation `delete_all` is
  scoped by `family_id`, also owner-bound (a family never crosses users).
- Concurrency: two concurrent refreshes of the same active token both pass the
  lookup before either stamps `revoked_at`. Acceptable within leeway (both are
  the "previous token"); they fork into the same family, and the unused branch
  ages out. Document it; don't try to serialize at the DB layer unless it bites.
- Client (plugin) already: persists access token (PR #84), dedups concurrent
  refreshes via `inflightRefresh`, awaits rotation persistence before use.
