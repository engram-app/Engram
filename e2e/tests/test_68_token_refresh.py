"""Test 68: OAuth access-token refresh keeps the WebSocket alive.

User path covered:
  OAuth access token expires mid-session.  The plugin's OAuthAuth.getToken()
  detects expiry (or invalidated token) and calls doRefresh() to obtain a new
  access token WITHOUT tearing down the WebSocket channel.  This test verifies
  that after a forced token invalidation followed by a fullSync, the same
  NoteChannel object is still in place (not a freshly-constructed one).

Skip conditions:
  - CI runs with API-key auth (no refreshToken configured) → skipped cleanly
    by the _require_oauth autouse fixture.
  - E2E_CLERK_SECRET_KEY not set → no way to provision an OAuth user → also
    results in a skip (the OAuth fixtures themselves skip).

Implementation notes vs plan draft:
  - Plan guessed field name `_accessToken` (underscore-prefixed).  Actual
    TypeScript source (src/auth.ts line 59) declares it as:
        private accessToken: string | null = null;
    TypeScript `private` is erased at runtime — the field is accessible from
    JS as `plugin.authProvider.accessToken` (no underscore).
  - Plan referenced `plugin.channel?.socket?.id` — this is a Phoenix-JS-client
    pattern.  The plugin uses its own NoteChannel class (src/channel.ts) which
    wraps a raw WebSocket.  There is no `.socket` property, no `.id` field.
    WebSocket identity is tracked instead by stamping a sentinel property
    (`__e2e_identity`) on the live `noteStream` object before the refresh.
    If the same object survives, its sentinel is still present; if
    setupNoteStream() replaced it with a new NoteChannel instance the sentinel
    is absent.  This survives socket-internal reconnects (NoteChannel.openSocket
    replaces this.ws but not the NoteChannel object itself) and correctly
    detects a full teardown (setupNoteStream() nulls out this.noteStream and
    constructs a new NoteChannel).
  - OAuthAuth.invalidateAccessToken() (src/auth.ts line 151) is the clean
    way to expire the token without corrupting the refresh-token rotation
    state.  We use it instead of direct field assignment.
  - The onTokenRotated callback in main.ts explicitly avoids calling
    saveSettings() (see the large comment at line 566) to prevent a reconnect
    loop — this test validates that contract holds.
"""

from __future__ import annotations

import asyncio

import pytest


PLUGIN_ID = "engram-vault-sync"
_P = f"app.plugins.plugins['{PLUGIN_ID}']"


@pytest.fixture(autouse=True)
async def _require_oauth(cdp_a):
    """Skip when the loaded plugin instance is using API-key auth (no refreshToken)."""
    has_refresh = await cdp_a.evaluate(
        f"Boolean({_P}.settings.refreshToken)"
    )
    if not has_refresh:
        pytest.skip(
            "Test requires OAuth auth; current instance uses API-key auth "
            "(no refreshToken configured). This test always skips in API-key CI."
        )


@pytest.fixture(autouse=True)
async def _require_invalidate_api(cdp_a):
    """Skip when authProvider lacks invalidateAccessToken() (pre-OAuthAuth builds)."""
    has_method = await cdp_a.evaluate(
        f"typeof {_P}.authProvider?.invalidateAccessToken === 'function'"
    )
    if not has_method:
        pytest.skip(
            "Plugin's authProvider lacks invalidateAccessToken() — "
            "OAuth-capable build not loaded."
        )


@pytest.mark.asyncio
async def test_refresh_does_not_reconnect_socket(cdp_a):
    """Token invalidation + fullSync triggers a refresh without replacing NoteChannel."""

    # ------------------------------------------------------------------ #
    # Step 1: stamp a sentinel on the current NoteChannel so we can detect
    #         if setupNoteStream() replaces it with a new instance.
    # ------------------------------------------------------------------ #
    stamped = await cdp_a.evaluate(
        f"""
        (() => {{
            const p = {_P};
            if (!p.noteStream) return false;
            p.noteStream.__e2e_identity = 'test68-sentinel';
            return true;
        }})()
        """
    )
    assert stamped is True, (
        "noteStream is null — WebSocket channel not connected, cannot run test"
    )

    # Confirm the channel is actually connected before we start.
    connected_before = await cdp_a.check_stream_connected()
    assert connected_before, "WebSocket must be connected before the token-refresh test"

    # ------------------------------------------------------------------ #
    # Step 2: expire the access token in-memory via the public invalidation
    #         API (sets accessToken=null, expiresAt=0).
    # ------------------------------------------------------------------ #
    await cdp_a.evaluate(
        f"{_P}.authProvider.invalidateAccessToken()"
    )

    # ------------------------------------------------------------------ #
    # Step 3: trigger a full sync.  getToken() will detect the null
    #         accessToken and call doRefresh().  The refresh token rotation
    #         callback (main.ts) only writes to disk — it does NOT call
    #         saveSettings() and does NOT call setupNoteStream(), so the
    #         existing NoteChannel must survive.
    # ------------------------------------------------------------------ #
    try:
        await cdp_a.trigger_full_sync()
    except Exception:
        # A network error (e.g. server not running in unit-test context)
        # is acceptable here — we only care about the WebSocket identity,
        # not whether sync succeeded.
        pass

    await asyncio.sleep(1)

    # ------------------------------------------------------------------ #
    # Step 4: verify the same NoteChannel object is still in place.
    # ------------------------------------------------------------------ #
    sentinel_still_present = await cdp_a.evaluate(
        f"{_P}.noteStream?.__e2e_identity === 'test68-sentinel'"
    )
    assert sentinel_still_present is True, (
        "NoteChannel was replaced after token refresh — setupNoteStream() must NOT "
        "be called from the token-rotation path (src/main.ts onTokenRotated comment "
        "explicitly guards against this to prevent refresh loops)."
    )

    # ------------------------------------------------------------------ #
    # Step 5: clean up the sentinel so we don't pollute downstream tests.
    # ------------------------------------------------------------------ #
    await cdp_a.evaluate(
        f"delete {_P}.noteStream.__e2e_identity"
    )
