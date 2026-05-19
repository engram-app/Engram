# E2E Vault-Registration Diagnostics

When an Obsidian E2E test fails with `TimeoutError: Vault not registered after 15s`, the cause is almost never the timeout itself. Skip the urge to bump the timeout — instead, follow this diagnostic ladder.

## Symptom

```
TimeoutError: Vault not registered after 15s on CDP port <N>
  plugin.registerVault → ['ok', False]
  api.registerVault    → ['err', 'Request failed, status XXX', XXX]
  api.listVaults       → ['err', 'Request failed, status XXX', XXX]
```

`wait_for_vault_registered` in `e2e/helpers/cdp.py` prints all three probes so the actual HTTP status is visible. **Do not infer the cause from `plugin.registerVault → ['ok', False]` alone** — `src/main.ts:514-522` collapses every error (401, 402, 5xx) into a single `false`, so the plugin-level result is *not* enough to distinguish causes.

## Cause matrix

| `api.registerVault` status | Meaning | Where to look |
|---|---|---|
| **401 Unauthorized** | API key was invalidated mid-suite. Backend `api_keys` table cascades from `users`, so a deleted Clerk user kills its API key. | `e2e/conftest.py:auth_provider`. The nuclear `cleanup_all_e2e_clerk_users()` deletes *every* user with email prefix `e2e-*` without run-id namespacing → two races: worker-vs-worker within one run, AND run-vs-run across concurrent CI. Tracking: [issue #160]. **Do not "fix" this by moving the sweep into a CI pre-step** — that just trades one race for a wider one; see issue for real fix options (per-run namespace, scheduled orphan reaper). |
| **402 Payment Required** | User hit `max_vaults` (default 1, see `lib/engram/billing.ex:16`). Something created a second vault for this user. | Check `api.listVaults` output — if `length > 1`, find the test that called `api.create_vault` or `api.register_vault` with a *different* `client_id`. Same `client_id` is idempotent and won't trip the limit. |
| **5xx Server Error** | Backend hiccup. Read the response body in pytest log; check `docker logs engram --tail 100` on the CI runner. | Usually transient; reruns mask it. If consistent, it's a real backend bug. |
| Network error (no status) | Backend unreachable. | Compose stack didn't fully boot — see the `wait_for_engram_ready` step in `docker-compose.ci.yml`. |
| `find_by_client_id` returns nil + `register_vault` returns OK | Plugin's `clientId` doesn't match what conftest's `api_sync.register_vault` used. | `e2e/helpers/obsidian.py:135-136` writes `clientId` into `data.json`; verify it matches `sync_client_id` from `conftest.py`. |

## How `wait_for_vault_registered` recovers

When `vaultId` is null on entry, the helper calls `plugin.registerVault()` once. The plugin's own guard at `src/main.ts:497` short-circuits when `vaultId` is already set, so the helper is idempotent and safe to call from any test setup path. If the active call still leaves `vaultId` null after the poll deadline, the diagnostic block above fires.

## What triggers `vaultId = null` mid-suite

Only one production code path nulls it: `channel.onVaultDeleted` at `src/main.ts:677-685`. That handler fires when the WebSocket channel receives a `vault_deleted` event. The backend's `lib/engram/notes.ex` broadcasts `note_changed` (`upsert` / `delete`), **not** `vault_deleted` — search confirms no `vault_deleted` broadcast exists in `lib/`. So in current CI runs, mid-suite `vaultId` clears should not happen organically. If you see one, suspect a test that's calling `setSyncBlocked(true)` or manipulating settings.vaultId directly (e.g. `test_71`'s stub) without restoring it correctly.

## Don't fix this with a timeout bump

- Increasing the 15s in `wait_for_vault_registered` won't help if the cause is 401 (it'll keep returning 401 forever).
- Adding `pytest-rerunfailures` retries hides the symptom. We tried — see `pytest.ini`'s TODO and issue #160.
- The right move when you see this is: **read the three diagnostic lines, find your row in the cause matrix above, fix the matched cause.**

## Plugin code references

- `src/main.ts:496-523` — `registerVault()` wrapper, collapses errors to bool.
- `src/main.ts:677-685` — `onVaultDeleted` handler (only place that nulls `vaultId`).
- `src/api.ts:132-138` — raw `EngramApi.registerVault` that throws with `.status`.
- `lib/engram/vaults.ex:70-113` — backend `register_vault` (idempotent by `client_id`).
- `lib/engram/billing.ex:16` — `max_vaults` default.

## Test harness references

- `e2e/helpers/cdp.py:wait_for_vault_registered` — the helper that emits the diagnostic.
- `e2e/conftest.py:auth_provider` — fixture with the xdist race (issue #160).
- `e2e/helpers/auth_provider.py:provision_user` — Clerk + API key creation flow.
