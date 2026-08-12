# Context Doc: stranded sync-preview modal cascades e2e "option not found"

_Last verified: 2026-08-12_

## Status

Working. Root causes fixed in backend PR #1367 (branch
`feat/first-sync-simple-modal`, paired with plugin PR
engram-app/Engram-obsidian#415).

## Symptom

Backend e2e run 31575779636 (triggered by plugin PR
engram-app/Engram-obsidian#415):

- 5 failures in `tests/test_51_sync_preview_modal.py::test_modal_choice_dispatches[*]`
- 3 failures in `test_55_sync_preview_destructive.py`
- All 8 with the identical error: `helpers.cdp.CdpError: Modal option
  '<label>' not found` (`helpers/cdp.py:534`)
- Plus: the headless-protocol job failed with
  `TypeError: engine.setCrdtCreateBatch is not a function`

## Root cause (two independent breaks)

**1. One-click first-sync screen has no option cards.** Plugin #415 collapses
any one-empty-side sync plan into a one-click first-sync screen with NO option
cards — `.engram-sync-preview-option-label` is absent; the simple screen uses
`.engram-sync-preview-simple-action` instead. test_51's `_seed_local_only`
produced exactly that plan on a fresh worker (empty server vault), so the
first dispatch test failed.

**2. CASCADE: one stranded modal, seven fallout failures.** The plugin's
`syncPreviewGuard` (single-flight in plugin `main.ts` ~line 331) makes
`open_sync_preview_modal` a SILENT NO-OP while any preview modal lives.
test_51's dispatch `finally` did not dismiss the stranded modal, so every
subsequent modal test (rest of test_51, all of test_55) queried the same
stuck modal and failed identically — 7 of the 8 failures were fallout from
one root failure. test_55's own seed was fine (two-sided).

> **Rule:** when many modal tests fail with identical "option not found",
> suspect ONE stranded modal, not many bugs.

**3. headless-protocol (independent).** `e2e/headless/run.ts` wired
`engine.setCrdtCreateBatch(...)` but plugin #413 deleted the client-side
batch RPC — this job has been red for EVERY plugin-main-based run since #413
merged; it went unnoticed because headless-protocol failures coincided with
other failures.

## Fix (backend PR #1367)

Branch `feat/first-sync-simple-modal` — the name matches the plugin branch so
e2e auto-pairs.

- test_51 dispatch tests seed BOTH sides (copied test_55's `_seed_divergent`
  pattern: `write_note` local + `api_sync.create_note` remote) so the
  five-option modal renders on every plugin version.
- dispatch `finally` now calls `cdp.dismiss_modals()` BEFORE restore, so a
  failed pick can't strand the modal.
- New feature-detected test
  `test_one_click_upload_screen_dispatches_smart_merge`: polls for
  `.engram-sync-preview-simple-action` vs `.engram-sync-preview-option-label`,
  skips on pre-#415 plugins or non-empty server vaults, else clicks the
  one-click button and asserts the dispatched choice is `smart-merge`.
- `run.ts`: deleted the `setCrdtCreateBatch` wiring line.

## The REAL strand source: oauth swap/restore (found via the DOM dump)

The test_51 finally-dismiss fix was necessary but test_55 kept failing at the
same suite position. The new `pick_modal_option` timeout dump showed the stuck
modal verbatim:

> "You are now pointing at a different cloud vault — This vault is empty on
> the server. Upload your 16 notes? — Upload everything / Cancel / Change vault"

A vault-switch-context ONE-CLICK screen with a stale plan. Decoded:

- `helpers/oauth.py` `swap_to_oauth`/`restore_auth` rotate the auth/vault
  fingerprint, which closes the sync gate; the `plugin.saveSettings()` they
  call then fire-and-forgets `doSyncWithFirstSyncCheck` for the closed gate —
  **opening a vault-switch SyncPreviewModal nobody answers**. The
  `markSyncGateAccepted()` that follows re-opens the gate but does NOT close
  the already-mounted modal.
- The stranded modal's plan was computed mid-rebind (channel down), so server
  enumeration read EMPTY → with plugin #415 that renders the one-click upload
  screen (no option cards). Pre-#415 the same stranded modal happened to
  contain the five option cards, so `pick_modal_option` clicked the STALE
  modal and tests passed by accident — #415 exposed the strand, it didn't
  create it.
- Local repro gotcha: test_47 is Clerk-gated (`E2E_CLERK_SECRET_KEY`), so a
  local-auth repro of the CI ordering SKIPS the trigger and test_55 passes —
  a green local run proved nothing until the DOM dump named the real culprit.

Fix: both oauth helpers now close `plugin.openPreviewModal` right after
`markSyncGateAccepted()` (inline JS) and `restore_auth` sweeps again after its
stream verify (the void re-fire can win the inline race).

## Gotchas for next time

- Writing e2e tests that open the sync-preview modal: ALWAYS
  `dismiss_modals()` in `finally`; the guard turns one stranded modal into a
  suite-wide cascade.
- A plan with one empty side renders the one-click screen (plugin ≥ #415) —
  seed both sides if the test needs option cards.
- `serverNoteCount` counts live rows only; whether a worker's server vault is
  empty depends on suite position (pytest-xdist distribution), so
  feature-detect rather than assume which screen renders.
