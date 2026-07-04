"""Unit tests for the delivery log-oracle (helpers/log_oracle.py).

Pure logic — no stack, no fixtures. The e2e root conftest boots the full
Obsidian stack via a session-autouse fixture, so run these with confcutdir
to skip it:

    cd e2e && python3 -m pytest helpers/log_oracle_test.py \
        --confcutdir helpers -o addopts='' --reruns 0 -p no:cacheprovider -q
"""

from __future__ import annotations

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
