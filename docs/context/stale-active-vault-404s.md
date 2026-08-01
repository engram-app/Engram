# Stale active vault → the whole vault-scoped API 404s

**Symptom.** The web app loads, but `GET /api/folders`, `/api/folders/list?folder=`,
and `/api/attachments` all return **404**. Often accompanied by
`WebSocket is closed before the connection is established` in the console.
Reloading does not help. Visiting a `/v/:slug` URL *does*.

## Diagnosis, in order

1. **Is the route actually missing?** Hit it unauthenticated:
   ```
   curl -s -o /dev/null -w '%{http_code}\n' https://<host>/api/folders   # 401 = route is fine
   ```
   `401` means the route exists and the deploy is current. A 404 with a *valid*
   JWT is therefore not a routing problem.

2. **Which plug produced the 404?** On the vault-scoped pipeline
   (`router.ex`, the `scope "/api"` that pipes through `VaultPlug`) only
   `VaultPlug` answers 404. `RequireOnboarding` rejects with **403**, auth with
   **401**. So a 404 always means "vault could not be resolved":
   `vault_id_malformed`, `vault_not_found`, or `no_default_vault`
   (`lib/engram_web/plugs/vault_plug.ex`).

3. **Which of the three?** Read the response body, or in prod query Loki for the
   `reject_reason` folded into the request-stop log line. Staging (FastRaid) does
   not ship to Loki — read the body there.
   - `"Vault not found"` → the client sent a dead `X-Vault-ID` (this doc).
   - `"No vault configured. Sync from Obsidian to create one."` → the account
     genuinely owns no vault; the onboarding gate should have routed them to
     `/onboard/vault`.

## Why a dead vault id sticks

The SPA persists the selected vault in `localStorage["engram.activeVaultId"]`
and `src/api/client.ts` ships it as `X-Vault-ID` on **every** request.

A stored id whose vault no longer exists — deleted from another device, or an
environment whose DB was wiped (staging is wipeable) — is a well-formed UUID.
Nothing rejects it client-side, so it keeps riding along and the backend 404s
everything.

**A stale id is strictly worse than no id.** With no header at all, `VaultPlug`
falls back to the user's default vault and the app works.

Only `/v/:slug` self-heals, because `VaultRoute` makes the URL authoritative and
holds render until the store agrees. On `/settings/*` and every other slugless
route the sidebar still mounts and fires the folder/attachment queries under the
dead id, forever.

## The reconcile, and why it lives where it does

`reconcileActiveVault(vaults)` in `src/api/active-vault.ts` re-points the store
at a vault the account owns, via `preferredVault` (hint → `is_default` → first).
It is called from **both** paths that learn the authoritative list:

- `useAppBootstrap`'s `queryFn` — inside the queryFn, **not** a gate-level
  effect. React runs passive effects child-first, so a parent effect fires after
  the sidebar's `useQuery` subscriptions have already dispatched, and the
  requests would still 404 once.
- `useVaults`'s `queryFn` — the path a delete/purge invalidation refetches
  through. Without it, deleting the vault you are currently in leaves the store
  pointing at it for the rest of the session.

**Re-point, never clear.** `use-channel.ts` early-returns while the active vault
is `null`, so clearing the bad id trades visible 404s for a silently dead
live-sync socket.

Deleting the *last* vault is a third case: vault count feeds `next_step` in
`lib/engram/onboarding.ex`, but the gate only reads that at bootstrap. The vault
mutations invalidate `["bootstrap"]` as well as `["vaults"]` so the gate re-runs
and redirects to `/onboard/vault`.

## Related console noise that is NOT this bug

Seen in the same staging session, all harmless:

- `WebSocket is closed before the connection is established` — `useChannel`'s
  effect is keyed on `[userId, vaultId]`; the id being corrected mid-handshake
  tears down a CONNECTING socket. A symptom of the above, not its own bug.
- `MaxListenersExceededWarning` / `ObjectMultiplex - orphaned data for stream
  "app-init-liveness"` in `contentscript.js` — a browser wallet extension.
- Sentry `net::ERR_CONNECTION_REFUSED` — a local DNS sinkhole / blocker.
  **Consequence: no frontend errors reach Sentry from that browser**, so "Sentry
  is quiet" proves nothing while testing there.
- `clerk-telemetry.com` CSP violations — fixed with `telemetry={{ disabled: true }}`
  on `ClerkProvider` rather than widening `connect-src` (see `csp.ex`).
