"""Test 67: Swapping API key in settings re-bootstraps the engine.

User path covered:
  1. Replace the valid API key with a bogus one via settings.
  2. Hit api.getChanges() — expect a 401-shaped failure surfacing the new
     (bogus) key. This is the smallest possible round-trip that proves the
     EngramApi instance picked up the new credential.
  3. Restore the original API key via settings.
  4. Hit api.getChanges() again — expect success. Then run one fullSync to
     confirm the note actually reaches the server (end-to-end recovery).

Why api.getChanges() instead of syncEngine.fullSync() for the bogus key:
  fullSync() runs retry/backoff and various preflight checks (~5-10 s on a
  401). The subject we're verifying is "after apiKey swap, the api client
  uses the new key" — a single HTTP call to /changes is sufficient. We
  still exercise fullSync on the restore phase to prove the engine-level
  path also recovers.

Implementation notes:
  - The real ping()/getChanges() error from api.ts on 401 is "Invalid API
    key" (src/api.ts line 156) — neither "auth" nor "401" appears in that
    string. Assertion checks for "invalid" or "api key" (case-insensitive)
    or "401" / "ok:false" as defensive matches.
  - saveSettings() calls api.updateConfig() which propagates the new key
    to the EngramApi instance immediately. ApiKeyAuth is stateless so the
    new key is in effect for the next request.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.vault import write_note


PLUGIN_ID = "engram-vault-sync"
BOGUS_KEY = "INVALID-DEFINITELY-NOT-A-KEY-test67"
NOTE_PATH = "E2E/AuthSwap67/During.md"


@pytest.mark.asyncio
async def test_swap_to_invalid_key_then_back(cdp_a, sync_user, vault_a, api_sync):
    """Bogus key surfaces auth error; restoring original key recovers sync."""
    original_key = sync_user[2]

    try:
        # ------------------------------------------------------------------ #
        # Phase 1: install bogus key and confirm auth error surfaces.
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.apiKey = {BOGUS_KEY!r};"
            f"  await p.saveSettings();"
            f"  p.authProvider = null;"
            f"  p.api.setAuthProvider(null);"
            f"}})()",
            await_promise=True,
        )

        # Seed a note so the recovery-phase fullSync has something to push.
        write_note(vault_a, NOTE_PATH, "# during bogus key\nshould fail to push")

        # Direct api.getChanges() call — single HTTP round-trip exercising
        # the new (bogus) key. Avoids fullSync's ~5-10s retry/backoff.
        signal = await cdp_a.evaluate(
            f"(async () => {{"
            f"  try {{"
            f"    const r = await app.plugins.plugins['{PLUGIN_ID}']"
            f".api.getChanges(0);"
            f"    return 'ok:' + JSON.stringify(r).slice(0, 80);"
            f"  }} catch (e) {{"
            f"    return e.message || String(e);"
            f"  }}"
            f"}})()",
            await_promise=True,
        ) or ""

        assert signal, (
            "api.getChanges(0) returned no signal at all after swapping in "
            "a bogus API key — neither resolved nor rejected with a message."
        )
        # The bogus key MUST cause a non-ok response or thrown error. A
        # successful resolve (starts with "ok:") means the auth swap was
        # ignored — that's a regression.
        assert not signal.startswith("ok:"), (
            f"api.getChanges(0) unexpectedly succeeded with bogus API key: "
            f"{signal!r}. The new (bogus) key did not propagate to api."
        )
        sig_lower = signal.lower()
        assert (
            "invalid" in sig_lower
            or "api key" in sig_lower
            or "connection" in sig_lower
            or "401" in sig_lower
            or "403" in sig_lower
            or "unauthor" in sig_lower
            or "forbidden" in sig_lower
        ), (
            f"Expected auth-related error (e.g. 'Invalid API key'), got: {signal!r}"
        )

        # ------------------------------------------------------------------ #
        # Phase 2: restore original key and confirm sync recovers.
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.apiKey = {original_key!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        # Accept the sync gate that saveSettings re-evaluates so fullSync
        # is not blocked by the fingerprint change.
        await cdp_a.accept_sync_gate()

        await cdp_a.trigger_full_sync()
        await asyncio.sleep(1)

        recovered_error = await cdp_a.get_last_error()
        assert not recovered_error, (
            f"Expected no lastError after restoring valid API key, "
            f"but got: {recovered_error!r}"
        )

        # Confirm the note reached the server after recovery.
        server_note = api_sync.get_note(NOTE_PATH)
        assert server_note is not None, (
            f"Note {NOTE_PATH!r} should have been pushed to server after key restore"
        )

    finally:
        # ------------------------------------------------------------------ #
        # Restore: ensure original key is in place and seeded note is cleaned.
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.apiKey = {original_key!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        await cdp_a.accept_sync_gate()

        note_file = vault_a / NOTE_PATH
        note_file.unlink(missing_ok=True)
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass
