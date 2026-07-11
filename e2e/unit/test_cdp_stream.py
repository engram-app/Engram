"""Unit tests for helpers.cdp stream diagnostics — no CI stack needed.

`wait_for_stream_connected()` must dump the channel's internal state on timeout,
so a recurrence of the e2e-clerk "Stream not connected after 20s" flake
(test_37/78/84/85) reports WHICH stuck state it hit (ws readyState, connected,
crdtJoined, crdtJoinFailedReason, pending reconnect) instead of a bare timeout —
CI does not capture plugin-runtime logs. This diagnostic is what surfaced the
real root cause: crdtJoinFailedReason="unauthorized" from an OAuth
identity-rebind ordering bug (fix in helpers/oauth.py + Engram-obsidian#229;
guarded by test_oauth_rebind.py).

These fake the CDP layer; they run without any stack.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from helpers.cdp import CdpClient

# Diagnostic JS reads these field names; the fake evaluate keys off them to
# recognise the diag snippet vs the plain disconnect()/connect() calls.
_DIAG_MARKERS = ("wsReadyState", "crdtJoinFailedReason")

_FAKE_DIAG = {
    "isLiveConnected": False,
    "wsReadyState": 0,
    "connected": False,
    "crdtJoined": False,
    "crdtJoinFailedReason": "rate_limited",
    "reconnectPending": True,
    "connId": None,
}


def _client(check_result: bool) -> tuple[CdpClient, list[str]]:
    """A CdpClient whose evaluate() records exprs and whose stream-connected
    probe returns ``check_result``. No websocket is opened."""
    client = CdpClient(port=1234)
    calls: list[str] = []

    async def fake_evaluate(expr: str, await_promise: bool = False):
        calls.append(expr)
        if any(m in expr for m in _DIAG_MARKERS):
            return json.dumps(_FAKE_DIAG)
        return None

    async def fake_check() -> bool:
        return check_result

    client.evaluate = fake_evaluate  # type: ignore[method-assign]
    client.check_stream_connected = fake_check  # type: ignore[method-assign]
    return client, calls


def test_wait_for_stream_connected_dumps_channel_diag_on_timeout():
    client, _calls = _client(check_result=False)

    with pytest.raises(TimeoutError) as exc:
        # timeout=0 → the poll loop never runs, straight to the diag+raise path.
        asyncio.run(client.wait_for_stream_connected(timeout=0))

    msg = str(exc.value)
    assert "Stream not connected" in msg
    # The channel snapshot must be surfaced so the stuck state is diagnosable.
    assert "crdtJoinFailedReason" in msg
    assert "rate_limited" in msg
    assert "wsReadyState" in msg


def test_wait_for_stream_connected_returns_when_connected():
    client, _calls = _client(check_result=True)
    # Should return without raising when the stream is up.
    asyncio.run(client.wait_for_stream_connected(timeout=5))
