# PR B2 (cursor-pull) — paired e2e failure triage

_Last verified: 2026-06-18_

**Date:** 2026-06-17
**Context:** Plugin PR `engram-app/Engram-obsidian#109` (cursor-pull migration) paired with merged backend B1 (#628). First paired e2e run (backend run 27665339557, `e2e-clerk`) had **5 failures**. This doc captures the root-cause so it isn't rediscovered.

## TL;DR
Core convergence WORKS (test_49 cross-auth push↔receive, test_50 live SSE, conflict/preview/special-chars all green). The 5 failures are: 3 obsolete-contract/accounting test-ports + 1 real B2 reconnect-catch-up bug (test_48 ×2).

## The 5 failures

| Test | Symptom | Verdict |
|---|---|---|
| `test_58_commands_palette::test_sync_now_advances_last_sync` | `lastSync` didn't change | **Obsolete** — B2 freezes `lastSync` (cursor is the watermark). Port: assert the cursor advances. |
| `test_59_status_bar_click::test_click_unblocked_triggers_sync` | `lastSync` didn't change | **Obsolete** — same. Port to cursor. |
| `test_44_oauth_device_flow::test_full_device_flow` | `Expected push, got {pulled:0,pushed:0}` | **Accounting** — B2 bootstrap pushes offline-created files INSIDE `bootstrap()`, so `fullSync`'s push counter reads 0 though the file reaches the server. Port: assert server-side arrival, not push count. |
| `test_48_oauth_reconnect_catchup::test_oauth_reconnect_catches_up` | `OAuthReconnect.md` never appeared after reconnect | **REAL BUG** (see below). |
| `test_48_oauth_reconnect_catchup::test_oauth_reconnect_receives_update` | V2 update never applied after reconnect | **REAL BUG** (same). |

## Evidence (from run-27665339557 vault tarballs)
- `e2e/helpers/obsidian.py:139` seeds `lastSync: "2020-01-01T00:00:00Z"` but **no `syncCursor`** → every e2e plugin starts in B2's bootstrap path.
- The `catches_up` worker vault: `OAuthReconnect.md` genuinely **absent**.
- The `receives_update` worker vault: file present (V1 via SSE) but V2 missing; `data.json` `syncCursor` = seq **83** (unchanged from before the disconnect), `lastSync` frozen `2020...`.
- Non-OAuth reconnect tests (`ChannelReconnect`, `TopicReconnectCheck`) PASSED — so the bug is specific to the **OAuth-swap path**.

## Root cause of test_48 (real bug)
`swap_to_oauth` (e2e/helpers/oauth.py) changes `vaultId` → B2's `SyncEngine.invalidateIfVaultChanged()` clears the cursor → the reconnect-time `pull()` (wired at plugin `main.ts:843` `channel.onStatusChange(connected) → syncEngine.pull()`) must **bootstrap** (manifest + full genesis pull), which is slow.

The cursor stayed at 83 and V2 (a later seq) was never pulled → most consistent with **the reconnect catch-up `pull()` being dropped by the `pulling` re-entry guard** (`if (this.pulling) return 0`) while the slow post-swap bootstrap is still in flight. A dropped catch-up = the missed change is never fetched (the cursor never advances, V2 never applied).

Secondary contributing issue: an **empty-vault genesis pull leaves the cursor null** (`pullViaCursor` only advances on `next_cursor`/`changes.length>0`), so a freshly-swapped empty vault never establishes a cursor → repeated full bootstraps. Spec §E actually said to set the cursor to `(change_seq, MAX_UUID)` after bootstrap (the `ManifestResponse.change_seq` field is typed in B2 but unused) — that's the intended fix for the empty case.

## Fix plan
**Plugin (PR #109 branch):**
1. **Coalesce a dropped pull** — if `pull()` is called while one is in flight, set a `pullRequested` flag and re-run once when the current pull finishes (so a reconnect catch-up is never silently lost to the re-entry guard). This is the primary test_48 fix.
2. **§E cursor-after-bootstrap** — after the genesis pull in `bootstrap()`, set the cursor from `manifest.change_seq` (`encodeCursor(change_seq, MAX_UUID)`) when the genesis pull left it null/behind, so the cursor always reflects the true head (fixes empty-vault + makes reconnect resume incremental instead of re-bootstrapping).

**Backend e2e (engram repo, pairs with #109):**
3. Port `test_58`/`test_59` → assert the cursor advances (add a `get_sync_cursor` CDP helper reading `plugin.syncEngine.getSyncCursor()`), not `lastSync`.
4. Port `test_44` → assert the created file arrives on the server (GET /notes or manifest), not `fullSync` push count.

**Verify:** re-dispatch the paired e2e via the plugin PR (`trigger-e2e` / `plugin_branch=feat/sync-cursor-pull-b2`), iterate to green.

## UPDATE 2026-06-17 — round 2 (run 27666381848, backend `fix/b2-cursor-e2e-ports` + plugin `feat/sync-cursor-pull-b2`)
**5 → 2 failures.** The 3 contract/accounting ports (test_44/58/59) now PASS. The 2 reconnect tests (test_48 ×2) STILL fail — the coalesce-pull + §E-cursor fixes did NOT resolve them.

Evidence (run-27666381848 w1-a vault `data.json`): `syncCursor` = seq **37** (`019ed3e9-c906-788a-8d66-4b521f2b7007`), note has V1 (via SSE), V2 (created-while-disconnected, a later seq) absent. So **no pull fetched seq>37 after V2 was created**, despite `main.ts:843` firing `pull()` on reconnect and `pullViaCursor(37)` *should* return seq>37.

Narrowed scope: live sync (test_49/50) AND non-swap reconnect-catch-up (ChannelReconnect/TopicReconnect) PASS. ONLY the **auth/vault-swap + reconnect-catch-up** path fails (`swap_to_oauth` changes vaultId → `invalidateIfVaultChanged` clears the cursor).

**Blocker:** the plugin runtime rlog (which shows what `pull()` actually did on reconnect — ran? errored? returned empty?) goes to the ephemeral CI backend and is gone. Can't pin from artifacts. Blind-fix wasted one e2e cycle.

## UPDATE 2026-06-17 — rounds 3-5: test_48 FIXED, test_24 regressed

**test_48 ROOT CAUSE + FIX (verified green round 4/5):** `invalidateIfVaultChanged()` (clears the per-vault cursor on a vault swap) was wired into `fullSync`/`pullAll` but NOT `pull()`. The reconnect catch-up calls `pull()` directly, so after `swap_to_oauth` the reconnect pull used the prior vault's cursor against the new vault — `getSyncChanges(seq > <foreign seq>)` returns nothing → disconnected-change never arrives, cursor frozen at the foreign seq. **Fix (plugin commit 9cfac7f):** call `invalidateIfVaultChanged()` at the top of `pull()`. test_48 ×2 now PASS.

**NEW regression: test_24_offline_queue_replay** ("Queue not drained after 10s, size=2"). Deterministic (failed initial + rerun in rounds 3 AND 4 = 4 consecutive; reruns=1). Passed rounds 1-2.
- test_24 does NOT swap vaults (`simulate_offline` only overrides `api.pushNote/health` to throw; `vaultId` unchanged), so `invalidateIfVaultChanged` is a state-level NO-OP there (no wipe, no saveData). The ONLY effect of the round-3 change is the extra `await invalidateIfVaultChanged()` tick at `pull()` start.
- Recovery path: `restore_online()` calls `flushQueue()` directly (await); separately, health-recovery → goOnline → `pull()`. The extra await shifted this race → queue (2 entries) not draining.
- In test_24 the cursor is SET (initial sync), so the recovery `pull()` is `pullViaCursor` (NOT bootstrap/§F) — so the "bootstrap §F double-pushes queued files" theory is NOT it.
- OPEN: exact race mechanism unconfirmed (needs runtime rlog / local repro). Candidates: (a) `pullViaCursor` applying a remote change to the offline-edited file mid-flush; (b) coalesce re-run interacting with the direct flushQueue; (c) a pre-existing flushQueue/goOnline double-invocation race that the await timing now loses.

**Status:** 4/5 original failures fixed (44/48×2/58/59 green). test_24 is a recovery-path timing regression exposed by the test_48 fix. Branches: plugin `feat/sync-cursor-pull-b2` (9cfac7f), backend e2e `fix/b2-cursor-e2e-ports`.

**Next options:** (A) instrument test_24/pull with CDP state capture + re-run; (B) local e2e repro (`make e2e` + Obsidian); (C) make the test_48 fix surgical (only null the stale cursor when `syncStateVaultId != vaultId` AND a cursor exists — skipped entirely when vault matches, so zero perturbation to test_24's timing) and re-run.

## RESOLVED 2026-06-17 — all e2e green (paired run 27667988219: 109 passed)
- **test_48** fixed by the **gated** vault-swap cursor invalidation in `pull()` (plugin: only call `invalidateIfVaultChanged()` when `getSyncCursor() != null && syncStateVaultId != null && syncStateVaultId != settings.vaultId`). Skipped entirely when the vault is unchanged → no hot-path perturbation.
- **test_24** root cause = the **coalesce-pull** change (a wrong-guess attempt at test_48: re-run a dropped pull via `pullRequested` + `setTimeout`). It added an extra recovery-time `pull()` that raced `flushQueue()` (offline-queue replay) → intermittent "Queue not drained". **Reverted** (it fixed no test). With coalesce gone + gated invalidate (no-op for test_24), test_24's path ≡ the passing round-1 code → green.
- Final plugin fix commits on `feat/sync-cursor-pull-b2`: `8abab94` (§E cursor seed — kept), `9cfac7f`→`c437ff4` (gated invalidate), `00bcddd` (revert coalesce). Backend e2e ports on `fix/b2-cursor-e2e-ports`.
- **Lesson:** verify a fix actually fixes the target before stacking more; the coalesce guess wasn't validated in isolation and introduced a race. Also: paired e2e MUST be run on a `workflow_dispatch` of the backend ports-branch with `plugin_branch=<fix branch>` — PR #109's auto `trigger-e2e` runs against backend `main` (no ports) and is red as a sequencing artifact.

**Merge sequencing (chicken-and-egg):** the backend e2e ports assert B2 behavior (fail vs plugin `main`); plugin #109's e2e needs the ports (fail vs backend `main`). Land plugin #109 first (accept the artifact-red `backend/e2e`; the paired run proves green), THEN open/merge the backend ports PR (its e2e then runs against plugin `main` with B2 → green).

## Key anchors
- Reconnect→pull wiring: plugin `src/main.ts:843`.
- Re-entry guard: plugin `src/sync.ts` `pull()` `if (this.pulling) return 0`.
- Cursor advance: plugin `src/sync.ts` `pullViaCursor` (final-page `encodeCursor`).
- Cursor clear on vault change: plugin `src/sync.ts` `invalidateIfVaultChanged` / `resetForVaultChange`.
- Bootstrap: plugin `src/sync.ts` `bootstrap()`.
- e2e seed: `engram/e2e/helpers/obsidian.py:139`; OAuth swap: `engram/e2e/helpers/oauth.py` `swap_to_oauth`.
