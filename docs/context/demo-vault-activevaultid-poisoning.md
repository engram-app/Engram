# Context Doc: Onboarding demo vault poisons `engram.activeVaultId` → prod 404 storm

_Last verified: 2026-07-05_

## Status
Diagnosed and FIXED 2026-07-05 (branch `fix/demo-vault-active-vault-poisoning`).
Core fix shipped: `active-vault.ts` never persists a `demo-vault-*` id (in-memory
only, so the tour switch still works), and `demo-vault-provider.tsx` `deactivate()`
calls `resetActiveVaultToStored()` to drop the transient demo selection. Follow-ups
still open: guard mutation hooks on `demo.active`, roll back optimistic inserts on
write failure (see Fix Direction).

## What This Is
The onboarding tour's demo vault leaks a `demo-vault-*` id into the real
`engram.activeVaultId` localStorage key. After the demo deactivates, every real
read/write ships `X-Vault-Id: demo-vault-N`, and the backend 404s the lot — no
such vault exists. A refresh cannot recover because the poisoned value is re-read
from localStorage at module init.

## Symptom (as reported)
Prod web app (app.engram.page), user mid-walkthrough:
- Editing a note created 2 duplicate notes at the root of the tree.
- The change never reflected to the Obsidian side.
- Refreshing did not fix it.
- An MCP-created note in a folder worked fine (different path — see below).

## Root Cause
- `demo-vault-*` / `demo-folder-*` / `demo-note-*` are hardcoded fixtures from the
  onboarding tour demo vault:
  - `frontend/src/onboarding/tour/demo-vault-provider.tsx` (loads `/demo-vault.json`)
  - IDs synthesized in `frontend/src/api/queries.ts` (~lines 309, 347, 1144).
- Read hooks in `queries.ts` guard on `demo?.active` (`enabled: !demo?.active`,
  return demo data when active) at ~lines 287, 327, 383, 1118. **The mutation hooks
  have NO demo guard.**
- `frontend/src/api/active-vault.ts`: `STORAGE_KEY = "engram.activeVaultId"`;
  module-level `activeVaultId = readStored()` reads localStorage at init;
  `setActiveVaultId(id)` persists it. `frontend/src/api/client.ts:22` puts
  `getActiveVaultId()` into the `X-Vault-Id` header on every request.
- **Chain:** selecting a demo vault (`layout/vault-switcher.tsx` → `setActiveVaultId`)
  persists `engram.activeVaultId = "demo-vault-2"` to localStorage. When the demo
  deactivates the value is never cleared. Now `demo.active = false`, so read hooks
  fetch for real, sending `X-Vault-Id: demo-vault-2` → backend 404 (no such vault).
  Refresh re-reads the poisoned value at module init → cannot self-recover.

## Why Each Symptom
- **MCP worked:** MCP goes through mcp.engram.page with the real vault, not this
  poisoned web-client localStorage state.
- **2 duplicates at root:** the note-edit POST 404'd (nothing persisted). The
  duplicates are client-side optimistic-cache rows never rolled back on the 404,
  rendered at root because the demo folder id is unresolvable. (Client-side
  inference; the server-side all-404 + nothing-persisted is certain.)
- **Not reflected to Obsidian:** nothing reached the DB, nothing to sync.
- **Refresh didn't fix:** poisoned localStorage `engram.activeVaultId` persists.

## User Recovery
Users already poisoned before this fix shipped **self-heal on the next load** —
`readStored()` drops a `demo-vault-*` value and clears the key. Manual escape
hatch if needed:
```js
localStorage.removeItem("engram.activeVaultId")
```
Then reload (or sign out / clear site data) so it falls back to the real default vault.

## Fix Direction
DONE (core):
- `active-vault.ts` `setActiveVaultId` skips `writeStored` for `demo-vault-*` ids
  (in-memory only) so a demo id can never persist and poison a reload.
- `active-vault.ts` `readStored()` drops + clears a persisted `demo-vault-*` id, so
  storage poisoned by a pre-fix tour session heals on the next load (otherwise those
  users 404 forever with no self-recovery).
- `active-vault.ts` `resetActiveVaultToStored()` re-reads localStorage into the
  in-memory selection; `demo-vault-provider.tsx` `deactivate()` calls it so leaving
  the tour restores the real vault (or null → VaultSwitcher self-heals to default).
- `demo-vault-ids.ts` is the single source of truth for the `demo-vault-` prefix,
  shared by the guard and `queries.ts` so they cannot drift.

Follow-ups (not in this fix):
- Guard mutation hooks on `demo.active` (parity with read hooks) so a demo edit
  never issues a real API write in the first place.
- Roll back optimistic inserts on write failure (kills the transient root duplicates).

## Observability (shipped with this fix)
`VaultPlug` assigns `:reject_reason`, which `RequestLogger` folds into the single
request-stop log line as `metadata_reason` (no second log per rejection — that
would double Loki ingest on the 4xx path). This whole class is now a one-line Loki
query instead of a trace dive:
- `vault_id_malformed` — a non-UUID `X-Vault-ID` (exactly this bug: `demo-vault-2`).
- `vault_not_found` — a well-formed id that does not resolve / is not owned.
- `no_default_vault` — no header and the user has no default vault.
Query: `{service_name="engram"} | json | metadata_reason="vault_id_malformed"`.
The line carries `trace_id`, so pivot to the Tempo span (and the Sentry request-env,
which still holds the raw `x-vault-id`) from there.

## Diagnosis Method (how to triage this class in prod)
Grafana Tempo (traces) + Loki (logs), prod.

**Loki** — datasource uid `grafanacloud-logs`, `service_name="engram"`, env prod.
- `metadata_request_path` is `[REDACTED]`. The FULL unredacted URL is in
  `metadata___sentry___request_env_REQUEST_URL` (method in `..._request_method`,
  vault in `metadata___sentry___request_headers_x_vault_id`), plus `metadata_user_id`,
  `x_device_id`, `trace`.
- Project with LogQL `| json | line_format ...`.

**Tempo** — datasource uid `grafanacloud-traces`, service `engram-backend`.
- Trace id is on each log line's `trace` field.
- Spans carry `phoenix.action`, `phoenix.plug`, `http.response.status_code`, and
  child `engram.repo.query:<table>` ecto spans.

### Evidence (this incident)
- user_id `019f3109-56e8-7473-8dc9-fcc51ed413e5`, device
  `d3678510-d960-454b-9899-051baa76440a`, ~2026-07-05T07:01Z. Every request 404,
  all carrying `X-Vault-Id: demo-vault-1` then `demo-vault-2`, hitting
  `demo-folder-1/2/3`. Includes `POST /api/notes` (the edit) and `POST /api/folders`
  (folder create), both 404.
- Tempo trace `9be0f8e1f1796d3639945c7a0b47520e` for the `POST /api/notes` 404:
  `phoenix.action=upsert`, only child DB spans were `users` and `subscriptions`
  (~1.3ms, healthy), then 404. Never reached the `notes` table → DB healthy; the
  write was rejected in the vault/auth pipeline.

## References
- `frontend/src/onboarding/tour/demo-vault-provider.tsx`
- `frontend/src/api/queries.ts` (~287, 309, 327, 347, 383, 1118, 1144)
- `frontend/src/api/active-vault.ts`
- `frontend/src/api/client.ts:22`
- `frontend/src/layout/vault-switcher.tsx`
- Related: `docs/context/search-contract-and-vault-id.md` (the X-Vault-Id / getActiveVaultId header story)
