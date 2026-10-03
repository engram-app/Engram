# E2E Vault-Registration Diagnostics

_Last verified: 2026-10-03_

When an Obsidian E2E test fails with `TimeoutError: Vault not registered after 15s`, the cause is almost never the timeout itself. Don't bump the timeout; follow this diagnostic ladder.

## Symptom

```
TimeoutError: Vault not registered after 15s on CDP port <N>
  plugin.registerVault → ['ok', False]
  api.registerVault    → ['err', 'Request failed, status XXX', XXX]
  api.listVaults       → ['err', 'Request failed, status XXX', XXX]
```

`wait_for_vault_registered` in `e2e/helpers/cdp.py` prints all three probes so the actual HTTP status is visible. **Do not infer the cause from `plugin.registerVault → ['ok', False]` alone**: the plugin's `registerVault()` (`src/main.ts`) collapses every error (401, 402, 5xx) into a single `false`.

## Cause matrix

| `api.registerVault` status | Meaning | Where to look |
|---|---|---|
| **401 Unauthorized** | API key was invalidated mid-suite. Backend `api_keys` cascades from `users`, so a deleted Clerk user kills its API key. | A Clerk sweep deleted a live user. Sweeps are namespaced per job (`_JOB_ID` in `e2e/conftest.py`, #869) with an age floor (`_SWEEP_MIN_AGE_SECONDS`) and live in `e2e/helpers/cleanup.py:cleanup_all_e2e_clerk_users`. Check whether a new sweep or a sibling job bypassed those. |
| **402 Payment Required** | User hit `vaults_cap` (free tier 1, `lib/engram/billing/limit_keys.ex`). Something created a second vault for this user. | Check `api.listVaults`: if `length > 1`, find the test that called `api.create_vault` or `api.register_vault` with a *different* `client_id`. Same `client_id` is idempotent. |
| **5xx Server Error** | Backend error. Read the response body in the pytest log and the backend container log. | If consistent, it's a real backend bug. |
| Network error (no status) | Backend unreachable. | Compose stack didn't fully boot; check the healthchecks in `ci/compose.yml`. |
| `find_by_client_id` returns nil + `register_vault` returns OK | Plugin's `clientId` doesn't match what conftest's `api_sync.register_vault` used. | `e2e/helpers/obsidian.py` writes `settings["clientId"]` into `data.json`; verify it matches `sync_client_id` from `conftest.py`. |

## How `wait_for_vault_registered` recovers

When `vaultId` is null on entry, the helper calls `plugin.registerVault()` once. The plugin short-circuits when `vaultId` is already set, so the helper is idempotent. If `vaultId` is still null after the poll deadline, the diagnostic block fires.

## What nulls `vaultId` mid-suite

- `channel.onVaultDeleted` (plugin `src/channel.ts`), on a `vault_deleted` channel event.
- The 404 "vault no longer exists" heal in plugin `src/main.ts`, which also blocks sync and reopens the vault picker.

If you see a mid-suite clear, suspect a test that deleted the vault, swapped auth, or set `settings.vaultId` / `setSyncBlocked(true)` directly (e.g. `test_71`'s stub) without restoring it.

## Don't fix this with a timeout bump or reruns

- A longer timeout won't help a 401; it keeps returning 401.
- Reruns are OFF suite-wide (`e2e/pytest.ini`); they masked real defects.
- Read the three diagnostic lines, find your row in the cause matrix, fix the matched cause.

## References

- Plugin `src/main.ts` `registerVault()`: collapses errors to bool.
- Plugin `src/api.ts` `EngramApi.registerVault`: throws with `.status`.
- `lib/engram/vaults.ex` `register_vault/4`: idempotent by `client_id`.
- `e2e/helpers/cdp.py:wait_for_vault_registered`: emits the diagnostic.
- `e2e/helpers/auth_provider.py:provision_user`: Clerk + API key creation.
