"""Unit tests for helpers.cdp stream-(re)connect helpers — no CI stack needed.

Regression lock for the e2e-clerk "Stream not connected after 20s" flake
(test_37/78/84/85). Two independent guarantees:

1. `reconnect_stream()` must FORCE a clean reconnect (disconnect THEN connect).
   The plugin's `channel.connect()` bails on `if (this.ws) return`, so calling
   connect() while a non-connected socket lingers is a no-op — the stream then
   stays down until its own up-to-60s backoff fires, blowing the 20s wait.
   Disconnecting first nulls `this.ws` + clears the backoff timer so connect()
   reliably opens a fresh socket.

2. `wait_for_stream_connected()` must dump the channel's internal state on
   timeout, so a recurrence reports WHICH stuck state it hit (ws readyState,
   connected, crdtJoined, crdtJoinFailedReason, pending reconnect) instead of a
   bare timeout — CI does not capture plugin-runtime logs.

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


def test_reconnect_stream_disconnects_before_connecting():
    # Stream reports connected right after the forced reconnect, so the poll
    # returns on the first check (no real sleeps).
    client, calls = _client(check_result=True)

    asyncio.run(client.reconnect_stream())

    # Match the full method call: "connect()" is a substring of "disconnect()",
    # so filter on the qualified name to tell the two calls apart.
    dis = [i for i, c in enumerate(calls) if "noteStream.disconnect()" in c]
    con = [i for i, c in enumerate(calls) if "noteStream.connect()" in c]
    assert dis, "reconnect_stream must disconnect() first to null a lingering socket"
    assert con, "reconnect_stream must connect() after disconnecting"
    assert dis[0] < con[0], "disconnect() must run strictly before connect()"


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
