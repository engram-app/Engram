"""Test 69: Echo suppression — WebSocket upsert for a recently-pushed path
is dropped by handleStreamEvent within the 5-second ECHO_COOLDOWN_MS window.

User path covered:
  After the plugin pushes a note to the server, the server broadcasts an
  upsert event back to all connected clients (including the originator).
  The plugin must ignore that echo so it doesn't overwrite the user's file
  with what it just wrote.  This protection lives in SyncEngine.handleStreamEvent
  (src/sync.ts ~line 1222): if recentlyPushed.has(event.path), the event is
  silently dropped.  After ECHO_COOLDOWN_MS (5000 ms) the suppression window
  expires and the same event would be processed.

Implementation notes vs plan draft:
  - Plan suggested `applyRemoteUpsert` — that method does not exist.  The
    actual WebSocket dispatcher is SyncEngine.handleStreamEvent (src/sync.ts
    line 1207, public async method).
  - Plan suggested `api_sync.broadcast_upsert(path)` — ApiClient has no such
    method and there is no debug-broadcast endpoint.  We drive the echo by
    calling syncEngine.handleStreamEvent() directly from CDP with a synthetic
    NoteStreamEvent.  This is the cleanest way to exercise the guard without
    requiring a real B→A WebSocket round-trip (which is inherently racy).
  - We spy on applyChange (the actual write method) rather than the OS-level
    vault.modify — this avoids ordering races with Obsidian's file watcher.
  - isRecentlyPushed() is a public method (src/sync.ts line 815) that exposes
    the recentlyPushed Map state; we verify it is set before the synthetic event
    so the test knows the suppression window is actually active.
  - The suppression window is 5 s; we wait 6 s for the expiry check to give
    a 1-second margin and add an extra second before the late-window assertion.
    CI is slow — 7 s total wait for the expiry is intentional.
  - handleStreamEvent is async; we await it inside evaluate() so the CDP call
    returns only after the method resolves.

Seed/restore notes:
  The test creates a file on vault_a and then deletes it.  triggerFullSync is
  called once at the end to clean up the server copy.  The spy is removed
  unconditionally in the finally block.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.vault import write_note, delete_note


PLUGIN_ID = "engram-vault-sync"
_P = f"app.plugins.plugins['{PLUGIN_ID}']"
_ENGINE = f"{_P}.syncEngine"


@pytest.fixture(autouse=True)
async def _require_echo_suppression(cdp_a):
    """Skip when the loaded build lacks the echo-suppression API."""
    has_api = await cdp_a.evaluate(
        f"typeof {_ENGINE}.isRecentlyPushed === 'function' && "
        f"typeof {_ENGINE}.handleStreamEvent === 'function'"
    )
    if not has_api:
        pytest.skip(
            "SyncEngine lacks isRecentlyPushed() or handleStreamEvent() — "
            "echo-suppression API not present in this build."
        )


@pytest.mark.asyncio
async def test_echo_suppressed_within_cooldown(vault_a, cdp_a):
    """handleStreamEvent drops an upsert event for a path that was recently pushed."""

    path = "E2E/Echo69/Loop.md"

    # ------------------------------------------------------------------ #
    # Seed: push a file from vault A so the server has a version and     #
    # recentlyPushed gets populated for this path.                       #
    # ------------------------------------------------------------------ #
    write_note(vault_a, path, "# echo seed")
    await cdp_a.trigger_full_sync()
    # Give Obsidian a moment to finish the push and set recentlyPushed.
    await asyncio.sleep(0.3)

    try:
        # Confirm the suppression window is actually active before proceeding.
        is_suppressed = await cdp_a.evaluate(
            f"{_ENGINE}.isRecentlyPushed({path!r})"
        )
        if not is_suppressed:
            pytest.skip(
                f"recentlyPushed not set for '{path}' immediately after sync — "
                "either the push debounce timer hasn't fired yet or the note "
                "was not pushed (server unavailable).  Cannot test echo suppression."
            )

        # ------------------------------------------------------------------ #
        # Install a spy on applyChange to detect if any write would occur.   #
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"""
            (() => {{
                window.__e2e_applyChangeCalled = 0;
                const engine = {_ENGINE};
                const orig = engine.applyChange.bind(engine);
                engine.__e2e_origApplyChange = orig;
                engine.applyChange = async (...args) => {{
                    window.__e2e_applyChangeCalled++;
                    return orig(...args);
                }};
            }})()
            """
        )

        # ------------------------------------------------------------------ #
        # Fire a synthetic upsert event for the same path.  Because the path #
        # is in recentlyPushed, handleStreamEvent must drop it immediately    #
        # without forwarding to applyChange.                                  #
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"""
            (async () => {{
                const engine = {_ENGINE};
                await engine.handleStreamEvent({{
                    event_type: 'upsert',
                    path: {path!r},
                    content: '# echo injected',
                    mtime: Date.now() / 1000,
                    updated_at: new Date().toISOString(),
                }});
            }})()
            """,
            await_promise=True,
        )

        handled = await cdp_a.evaluate("window.__e2e_applyChangeCalled")
        assert handled == 0, (
            f"applyChange was called {handled} time(s) — echo was NOT suppressed "
            "within the 5-second ECHO_COOLDOWN_MS window.  Check recentlyPushed "
            "logic in src/sync.ts handleStreamEvent."
        )

        # ------------------------------------------------------------------ #
        # Wait for the suppression window to expire (~5 s + margin).         #
        # ------------------------------------------------------------------ #
        await asyncio.sleep(7)

        # Verify the window has expired.
        still_suppressed = await cdp_a.evaluate(
            f"{_ENGINE}.isRecentlyPushed({path!r})"
        )
        assert not still_suppressed, (
            "recentlyPushed entry was NOT cleared after 7 seconds — "
            "ECHO_COOLDOWN_MS timer may not be firing.  Check setTimeout in "
            "SyncEngine.markRecentlyPushed (src/sync.ts)."
        )

        # Fire the same event again — now outside the window, applyChange should run.
        await cdp_a.evaluate(
            f"""
            (async () => {{
                const engine = {_ENGINE};
                await engine.handleStreamEvent({{
                    event_type: 'upsert',
                    path: {path!r},
                    content: '# echo injected late',
                    mtime: Date.now() / 1000,
                    updated_at: new Date().toISOString(),
                }});
            }})()
            """,
            await_promise=True,
        )

        handled_late = await cdp_a.evaluate("window.__e2e_applyChangeCalled")
        assert handled_late >= 1, (
            "applyChange was NOT called after the echo suppression window expired — "
            "events outside the cooldown period must be processed normally."
        )

    finally:
        # Remove spy unconditionally.
        await cdp_a.evaluate(
            f"""
            (() => {{
                const engine = {_ENGINE};
                if (engine.__e2e_origApplyChange) {{
                    engine.applyChange = engine.__e2e_origApplyChange;
                    delete engine.__e2e_origApplyChange;
                }}
                delete window.__e2e_applyChangeCalled;
            }})()
            """
        )
        # Clean up the seeded file.
        delete_note(vault_a, path)
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass
