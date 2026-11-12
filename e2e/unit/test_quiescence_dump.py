"""await_quiescent's timeout dump: never masks the settle failure, never leaks content."""

import asyncio

import pytest

from helpers.cdp import CdpClient
from helpers.quiescence import await_quiescent


class _DumpFails:
    """A cdp whose every evaluate raises, as a wedged renderer would."""

    async def evaluate(self, expr, await_promise=False, timeout=120):  # noqa: ARG002
        raise RuntimeError("renderer wedged")

    async def get_queue_entries(self, timeout=120):  # noqa: ARG002
        raise RuntimeError("renderer wedged")

    async def get_crdt_queue_ops(self, timeout=120):  # noqa: ARG002
        raise RuntimeError("renderer wedged")


def test_failed_dump_keeps_the_settle_assertion():
    with pytest.raises(AssertionError) as exc:
        asyncio.run(await_quiescent(_DumpFails(), api=None, deadline_s=0, kick=False))
    msg = str(exc.value)
    assert msg.startswith("sync did not settle within 0s"), msg
    assert "queue dump failed" in msg, msg


class _Recorder:
    def __init__(self, reply):
        self.reply = reply
        self.calls = []

    async def evaluate(self, expr, await_promise=False, timeout=120):  # noqa: ARG002
        self.calls.append((expr, timeout))
        return self.reply


def test_queue_entries_js_is_metadata_only_and_bounded():
    rec = _Recorder("[]")
    asyncio.run(CdpClient.get_queue_entries(rec, timeout=5))
    expr, timeout = rec.calls[0]
    assert timeout == 5
    for field in ("evidenced", "priority", "noteId", "crdt", "nextAttemptAt"):
        assert f"e.{field}" in expr, field
    assert "e.content" not in expr
    assert "contentBase64" not in expr
    # Mixed f-string/plain concatenation: a doubled brace in the plain part
    # ships a JS SyntaxError that only surfaces at the timeout it diagnoses.
    assert expr.count("{") == expr.count("}") and expr.count("(") == expr.count(")")


def test_crdt_ops_js_copies_payload_path_only():
    rec = _Recorder([])
    asyncio.run(CdpClient.get_crdt_queue_ops(rec, timeout=5))
    expr, timeout = rec.calls[0]
    assert timeout == 5
    for field in ("o.id", "o.vaultId", "o.payload?.path"):
        assert field in expr, field
    assert "o.payload " not in expr and "o.payload," not in expr and "o.payload)" not in expr
