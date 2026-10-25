# Refresh token rotation — reuse detection + leeway (as-built)

_Last verified: 2026-10-24_

Applies to the device-flow (`Engram.Auth.DeviceFlow`) and local-auth
(`Engram.Accounts`) refresh paths, which share `Engram.Auth.RefreshLeeway`. MCP
OAuth refresh (`Engram.OAuth`) has its own 60 s grace re-issue instead, with a
different shape (see `mcp-oauth.md`, "Refresh grace window"). Policy per RFC 9700 §4.14.2:
rotation plus reuse detection with family revocation, and a short leeway for
benign retries.

## As built

- **Schema** — `Engram.Auth.DeviceRefreshToken` has a `family_id :uuid` column
  required in the changeset. Each existing row was
  backfilled with its own fresh family.
- **`create_refresh_token/3`** (private, `device_flow.ex`) takes an optional
  `family_id`; `nil` mints a fresh uuid (new login), rotation inherits the old
  token's `family_id` to keep the lineage together.
- **`refresh_access_token/1`** looks up by hash where
  `expires_at > now` (regardless of `revoked_at`), then:
  - not found → `{:error, :invalid_refresh_token}`
  - active (`revoked_at` nil) → rotate: stamp `revoked_at`, issue child in same
    family.
  - revoked **within** leeway → benign retry: `issue_child` in same family, no
    re-revocation.
  - revoked **outside** leeway (or older token) → **reuse breach**:
    `invalidate_family/1` runs `delete_all where family_id == ^fid` and returns `{:error, :invalid_refresh_token}`. It
    **deletes** rather than `update_all` set `revoked_at` — a freshly-revoked
    current token would otherwise land *inside* the leeway and be misclassified
    as benign on next presentation. A `Logger.warning` records the breach
    (`family_id` + `user_id`) so the audit trail survives row deletion.
- **Leeway policy** — `Engram.Auth.RefreshLeeway` (`@seconds 30`,
  boundary-inclusive `benign?/2`). The 2026-10-24 speed audit found 27 plugin
  users logged out by reuse detection in 7 days and proposed 60 s like MCP
  OAuth. Rejected for now (review of #2209): within the window this path
  mints a child with no successor-unused check, no revoke of the live
  successor and no cap, so a wider window widens an undetected family fork.
  Raise it together with porting MCP's checks into one shared module.
- **Reuse log** carries `seconds_since_revoked`: seconds = duplicate concurrent
  presentation, hours = a second device sharing a synced token or a rotation
  the client never persisted.
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
  ages out. A `FOR UPDATE` row lock was tried in #2209 and cut: the second
  refresh still takes the benign branch and mints a child, so the fork and
  every user-visible outcome stay the same. The real fix is MCP's
  successor-unused check and re-issue cap (#2211).
- Client (plugin) already: persists access token (PR #84), dedups concurrent
  refreshes via `inflightRefresh`, awaits rotation persistence before use.
