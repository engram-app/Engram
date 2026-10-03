# Context Doc: stranded sync-preview modal cascades e2e "option not found"

_Last verified: 2026-10-03_

## Symptom

Many modal tests (`test_51_sync_preview_modal`, `test_55_sync_preview_destructive`)
fail with the identical `helpers.cdp.CdpError: Modal option '<label>' not found`.

> **Rule:** when many modal tests fail with identical "option not found",
> suspect ONE stranded modal, not many bugs.

## Why it cascades

The plugin's `syncPreviewGuard` (single-flight, plugin `src/main.ts`) makes
`open_sync_preview_modal` a SILENT NO-OP while any preview modal lives. One
modal left open means every later modal test queries the same stuck modal and
fails identically.

## Known strand sources

- **A test's own `finally` not dismissing.** Fixed in test_51 (#1367); any new
  modal test must do the same.
- **oauth swap/restore.** `helpers/oauth.py` `swap_to_oauth`/`restore_auth`
  rotate the auth/vault fingerprint, which closes the sync gate; the
  `saveSettings()` they call fire-and-forgets a first-sync check that opens a
  vault-switch modal nobody answers. Both helpers now close
  `plugin.openPreviewModal` after `markSyncGateAccepted()`, and `restore_auth`
  sweeps again after its stream verify.
- **The one-click screen.** A plan with one empty side (plugin >= #415)
  renders a one-click first-sync screen with no option cards
  (`.engram-sync-preview-simple-action`, not `.engram-sync-preview-option-label`).

The `pick_modal_option` timeout dumps the stuck modal's text; read it to name
the strand source.

## Gotchas

- Writing e2e tests that open the sync-preview modal: ALWAYS
  `dismiss_modals()` in `finally`.
- Seed both sides (local `write_note` + remote `api_sync.create_note`) if the
  test needs option cards.
- Whether a worker's server vault is empty depends on suite position
  (pytest-xdist distribution), so feature-detect which screen renders rather
  than assume.
- test_47 is Clerk-gated (`E2E_CLERK_SECRET_KEY`), so a local-auth repro of the
  CI ordering skips the oauth strand trigger. A green local run proves nothing.
