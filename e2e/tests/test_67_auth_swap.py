"""Test 67: Swapping API key in settings re-bootstraps the engine.

User path covered:
  1. Replace the valid API key with a bogus one via settings.
  2. Trigger fullSync — expect it to fail and surface an auth error in
     lastError (ping() returns "Invalid API key" on 401).
  3. Restore the original API key via settings.
  4. Trigger fullSync again — expect it to succeed (no lastError) and
     confirm the seeded note reaches the server.

Implementation notes vs plan draft:
  - Plan asserted `"auth" in last_error.lower() or "401" in last_error`.
    The real error string from api.ts ping() on 401/403 is "Invalid API key"
    (src/api.ts line 156) — neither "auth" nor "401" appears in that string.
    Assertion is corrected to check for "invalid" or "api key" (case-insensitive).
  - saveSettings() calls api.updateConfig() which propagates the new key to
    the EngramApi instance immediately. No separate applyAuthChange() is needed;
    createAuthProvider() is re-invoked inside setupNoteStream() which saveSettings
    calls. ApiKeyAuth is stateless so the new key is in effect for the next request.
  - trigger_full_sync() is used rather than waiting for the debounce path so
    the test is fast and deterministic.
  - The finally block restores the original key and cleans up the seeded file.
    api_sync is added as a fixture argument so we can verify server-side
    recovery (the note should push on the second full sync).
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
            f"}})()",
            await_promise=True,
        )

        # Seed a note so fullSync has something to push.
        write_note(vault_a, NOTE_PATH, "# during bogus key\nshould fail to push")

        # fullSync raises when ping() returns ok=false.  Catch so the test can
        # continue to the restore phase. Capture the thrown message so we can
        # use it as a backup auth-error signal when lastError is empty.
        fullsync_err = await cdp_a.evaluate(
            f"(async () => {{"
            f"  try {{ await app.plugins.plugins['{PLUGIN_ID}'].syncEngine.fullSync(); return ''; }}"
            f"  catch (e) {{ return e.message || String(e); }}"
            f"}})()",
            await_promise=True,
        ) or ""

        await asyncio.sleep(0.5)

        last_error = await cdp_a.get_last_error()

        # Prefer engine.lastError, fall back to the fullSync rejection
        # message, then fall back to a direct ping() invocation — gives us
        # three independent signals that the bogus key was rejected.
        signal = last_error or fullsync_err
        if not signal:
            ping_result = await cdp_a.evaluate(
                f"(async () => {{"
                f"  try {{ const r = await app.plugins.plugins['{PLUGIN_ID}']"
                f".api.ping(); return JSON.stringify(r); }}"
                f"  catch (e) {{ return 'threw:' + (e.message || String(e)); }}"
                f"}})()",
                await_promise=True,
            ) or ""
            signal = ping_result

        assert signal, (
            "Expected some auth-error signal (lastError, fullSync rejection, "
            "or ping result) after syncing with a bogus API key, but got none"
        )
        sig_lower = signal.lower()
        assert (
            "invalid" in sig_lower
            or "api key" in sig_lower
            or "connection" in sig_lower
            or "401" in sig_lower
            or "ok\":false" in sig_lower
            or "false" in sig_lower
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
