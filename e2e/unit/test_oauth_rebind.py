"""Unit tests for helpers.oauth swap/restore identity rebind — no CI stack.

Regression lock for the e2e-clerk test_84/85 "Stream not connected" flake. The
plugin freezes the WS channel's topic userId from api.getMe() when the channel
is rebuilt by saveSettings(); if the auth provider is swapped AFTER that rebuild
the channel carries the old user's id while the socket authenticates as the new
user, and the join is rejected "unauthorized" (mirrors the prod bug fixed in
Engram-obsidian#229 main.ts saveOAuthTokens).

Two invariants:
1. swap_to_oauth / restore_auth must wire the provider BEFORE saveSettings().
2. restore_auth must VERIFY the rebind (stream reconnects) and raise on a
   cross-bind, so a broken restore fails at the restore site instead of
   silently poisoning every later test that reuses the session-scoped device.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from helpers.oauth import restore_auth, swap_to_oauth

_ORIGINAL = json.dumps(
    {
        "apiKey": "k",
        "refreshToken": "r",
        "vaultId": "v",
        "userEmail": "e@x.com",
        "authMethod": "apikey",
    }
)


class _FakeCdp:
    """Records evaluate() JS; wait_for_stream_connected honours ``stream_ok``."""

    def __init__(self, stream_ok: bool = True):
        self.evals: list[str] = []
        self.stream_ok = stream_ok

    async def evaluate(self, expr: str, await_promise: bool = False):
        self.evals.append(expr)
        if "JSON.stringify({apiKey" in expr:
            return _ORIGINAL
        return "ok"

    async def wait_for_stream_connected(self, timeout: float = 10) -> None:
        if not self.stream_ok:
            raise TimeoutError(
                f"Stream not connected after {timeout}s — "
                'channel={"crdtJoinFailedReason":"unauthorized"}'
            )


def _provider_before_save(js: str) -> bool:
    # Match the actual `plugin.`-prefixed calls, not the bare names that also
    # appear in explanatory comments.
    prov = js.find("plugin.createAuthProvider()")
    save = js.find("plugin.saveSettings()")
    return prov != -1 and save != -1 and prov < save


def test_swap_to_oauth_wires_provider_before_savesettings():
    cdp = _FakeCdp()
    asyncio.run(swap_to_oauth(cdp, {"refresh_token": "rt", "vault_id": "vid", "user_email": "u@e.com"}))
    swap_js = next(e for e in cdp.evals if "createAuthProvider" in e)
    assert _provider_before_save(swap_js), "swap must wire the provider before saveSettings()"


def test_restore_auth_wires_provider_before_savesettings():
    cdp = _FakeCdp()
    asyncio.run(restore_auth(cdp, _ORIGINAL))
    restore_js = next(e for e in cdp.evals if "auth restored" in e)
    assert _provider_before_save(restore_js), "restore must wire the provider before saveSettings()"


def test_restore_auth_verifies_and_returns_when_connected():
    cdp = _FakeCdp(stream_ok=True)
    # Should not raise: the restored identity's stream reconnects.
    asyncio.run(restore_auth(cdp, _ORIGINAL))


def test_restore_auth_raises_on_cross_bind():
    cdp = _FakeCdp(stream_ok=False)
    with pytest.raises(TimeoutError):
        asyncio.run(restore_auth(cdp, _ORIGINAL))
