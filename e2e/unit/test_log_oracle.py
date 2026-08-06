"""Unit tests for the delivery log-oracle (helpers/log_oracle.py).

Pure logic — no stack, no fixtures. Lives under e2e/unit/ (standalone
pytest rootdir + a conftest that puts e2e/ on sys.path) so e2e/conftest.py
(the Obsidian/auth session-autouse fixtures) never loads. Runs in CI via
the "Harness unit tests" step; locally:

    cd e2e/unit && python3 -m pytest test_log_oracle.py -q
"""

from __future__ import annotations

import json

import pytest

from helpers.log_oracle import wait_for_binary_delivery, wait_for_delivery


class _FakeApi:
    """Stand-in for the ApiClient — serves canned GET /logs rows."""

    def __init__(self, logs=None, raise_on_get=False):
        self._logs = logs or []
        self._raise = raise_on_get
        self.get_calls = 0

    def get_logs(self, limit=200):
        self.get_calls += 1
        if self._raise:
            raise RuntimeError("boom")
        return {"logs": self._logs}


def _pull_created(path):
    return {"category": "pull", "level": "info", "message": f"Created: {path} | len=5"}


def _channel_event(path):
    return {"category": "channel", "level": "info", "message": f"Event: upsert {path}"}


def test_returns_content_when_file_appears(tmp_path):
    """On success it behaves like wait_for_file: returns content, never queries logs."""
    rel = "E2E/Ok.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("hello body", encoding="utf-8")
    api = _FakeApi(raise_on_get=True)  # would blow up if the oracle queried logs

    content = wait_for_delivery(tmp_path, rel, api, timeout=1, poll=0.02)

    assert content == "hello body"
    assert api.get_calls == 0


def test_zero_byte_note_is_not_ready(tmp_path):
    """A 0-byte note is the read-before-flush window, not a delivery → keep waiting.

    Regression for the bug where wait_for_delivery returned "" the instant the
    file existed, so a caller's `assert "x" in ""` failed WITHOUT this oracle's
    causal-chain diagnostic ever firing (test_50 line 138).
    """
    rel = "E2E/Empty.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("", encoding="utf-8")
    api = _FakeApi(logs=[])

    with pytest.raises(TimeoutError):
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)


def test_waits_past_empty_window_then_returns_content(tmp_path):
    """File appears empty first, gets its body a beat later → returns the body."""
    import threading

    rel = "E2E/Late.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("", encoding="utf-8")  # 0-byte window, as sync creates it
    threading.Timer(0.1, full.write_text, args=("flushed body",)).start()
    api = _FakeApi(raise_on_get=True)  # must succeed without touching logs

    content = wait_for_delivery(tmp_path, rel, api, timeout=2, poll=0.02)

    assert content == "flushed body"
    assert api.get_calls == 0


def test_timeout_reports_received_but_not_materialized(tmp_path):
    """Server delivered (channel Event) but client never wrote → pointed diagnosis."""
    rel = "E2E/Stuck.md"
    api = _FakeApi(logs=[_channel_event(rel)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "received=yes" in msg
    assert "materialized=no" in msg
    assert rel in msg
    assert api.get_calls == 1


def test_timeout_reports_never_received(tmp_path):
    """No client log mentions the path → received=no materialized=no."""
    rel = "E2E/Ghost.md"
    api = _FakeApi(logs=[_channel_event("E2E/Unrelated.md")])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "received=no" in msg
    assert "materialized=no" in msg


def test_timeout_reports_materialized(tmp_path):
    """A pull 'Created:' line for the path counts as materialized."""
    rel = "E2E/Written.md"
    api = _FakeApi(logs=[_channel_event(rel), _pull_created(rel)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "received=yes" in msg
    assert "materialized=yes" in msg


def test_timeout_survives_log_query_failure(tmp_path):
    """A failed log query must not mask the real TimeoutError."""
    rel = "E2E/NoLogs.md"
    api = _FakeApi(raise_on_get=True)

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    assert rel in str(exc.value)


def _pull_attachment(path):
    return {
        "category": "pull",
        "level": "info",
        "message": f"Attachment created: {path} | bytes=3",
    }


def test_binary_returns_bytes_when_file_appears(tmp_path):
    """Attachment variant: returns bytes on success, never queries logs."""
    rel = "E2E/img.png"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_bytes(b"PNG")
    api = _FakeApi(raise_on_get=True)

    data = wait_for_binary_delivery(tmp_path, rel, api, timeout=1, poll=0.02)

    assert data == b"PNG"
    assert api.get_calls == 0


def test_binary_zero_byte_is_not_ready(tmp_path):
    """A 0-byte placeholder is not a delivered attachment → still times out."""
    rel = "E2E/empty.png"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_bytes(b"")
    api = _FakeApi(logs=[])

    with pytest.raises(TimeoutError):
        wait_for_binary_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)


def test_binary_timeout_reports_attachment_materialized(tmp_path):
    """A pull 'Attachment created:' line counts as materialized for attachments."""
    rel = "E2E/late.png"
    api = _FakeApi(logs=[_pull_attachment(rel)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_binary_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "materialized=yes" in msg
    assert rel in msg


# ---------------------------------------------------------------------------
# Device attribution + byte tracking
#
# The lines below are TRANSCRIBED FROM A REAL FAILURE (nightly run
# 30341324024, job 90217503134, test_34_folder_rename_propagation). That run
# reported "received=yes materialized=no", which was wrong twice over: the
# receiver HAD written the path, and the reason the test failed is that its
# last write was 0 bytes. Both instances log under one client_id, so the
# sender's healthy "bytes=22" sat in the same evidence blob as the receiver's
# empty write.
# ---------------------------------------------------------------------------

DEV_A = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
DEV_B = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"


def _vault_write(path, kind, nbytes, device=None):
    row = {
        "category": "vault",
        "level": "diag",
        "message": f"{kind} path={path} bytes={nbytes}",
    }
    if device:
        row["device_id"] = device
    return row


def _crdt_discovery(path, device=None):
    row = {
        "category": "pull",
        "level": "info",
        "message": f"CRDT discovery: enrolling new note {path}",
    }
    if device:
        row["device_id"] = device
    return row


def _write_device_id(vault_path, device_id):
    d = vault_path / ".obsidian" / "plugins" / "engram-vault-sync"
    d.mkdir(parents=True, exist_ok=True)
    (d / "data.json").write_text(json.dumps({"deviceId": device_id}), encoding="utf-8")


def test_crdt_materialize_is_no_longer_invisible(tmp_path):
    """A CRDT-bound write emits no 'Created:'/'Applied:' — only a vault event.

    Before byte/vault tracking this reported materialized=no on every
    CRDT-managed note, which sent debugging after a delivery gap that wasn't
    there.
    """
    rel = "E2E/RenamedFolder34/Note1.md"
    api = _FakeApi(logs=[_channel_event(rel), _vault_write(rel, "create", 22)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "materialized=yes" in msg
    assert "last_write=22B" in msg


def test_zero_byte_clobber_is_named_not_reported_as_a_delivery_gap(tmp_path):
    """The real test_34 shape: written with content, then overwritten empty."""
    rel = "E2E/RenamedFolder34/Note1.md"
    api = _FakeApi(
        logs=[
            _channel_event(rel),
            _crdt_discovery(rel),
            _vault_write(rel, "create", 22),
            _vault_write(rel, "create", 0),
            _vault_write(rel, "modify", 0),
        ]
    )

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "materialized=yes" in msg
    assert "last_write=0B" in msg
    assert "LEFT IT EMPTY" in msg


def test_sender_writes_do_not_mask_an_empty_receiver(tmp_path):
    """With a device id, only the RECEIVER's writes count.

    A and B share a client_id, so A's healthy bytes=22 is in the same log
    stream. Attributed to B, the verdict must still be 0 bytes.

    Ordering is deliberate — the SENDER's line comes LAST. That is the case
    where an unattributed oracle actively lies: it reports last_write=22B and
    the empty file on B looks healthy. (With the sender first, "last write
    wins" happens to land on B's 0 and the bug is named by luck, so that
    ordering would not fail without the fix.)
    """
    rel = "E2E/RenamedFolder34/Note1.md"
    _write_device_id(tmp_path, DEV_B)
    api = _FakeApi(
        logs=[
            _channel_event(rel) | {"device_id": DEV_B},
            _vault_write(rel, "create", 0, device=DEV_B),  # the RECEIVER, empty
            _vault_write(rel, "create", 22, device=DEV_A),  # the SENDER, healthy
        ]
    )

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert f"device={DEV_B[:8]}" in msg
    assert "last_write=0B" in msg, "A's 22-byte write must not be credited to B"
    assert "bytes=22" not in msg, (
        "the sender's line must be filtered out of the evidence"
    )


def test_missing_data_json_degrades_to_unknown_and_says_so(tmp_path):
    """No data.json → keep working, but flag that evidence may be cross-device."""
    rel = "E2E/NoDeviceId.md"
    api = _FakeApi(logs=[_channel_event(rel)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "device=UNKNOWN" in msg
    assert "category heuristic" in msg


def test_sibling_path_containing_rel_path_is_not_counted(tmp_path):
    """`rel_path in message` also matches a longer sibling — parse, don't substring."""
    rel = "E2E/Note.md"
    api = _FakeApi(logs=[_vault_write("E2E/Note.md.backup", "create", 99)])

    with pytest.raises(TimeoutError) as exc:
        wait_for_delivery(tmp_path, rel, api, timeout=0.1, poll=0.02)

    msg = str(exc.value)
    assert "materialized=no" in msg
    assert "last_write" not in msg
