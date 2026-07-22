"""Unit tests for the delivery budget + latency recorder (helpers/latency.py).

Pure stdlib logic — no stack, no fixtures. Runs in CI via the "Harness
unit tests" step; locally:

    cd e2e/unit && python3 -m pytest test_latency.py -q
"""

from __future__ import annotations

import json

import helpers.latency as latency


def test_record_appends_jsonl(tmp_path, monkeypatch):
    """Each record() call appends one parseable JSON line with the schema fields."""
    log = tmp_path / "latency-report.jsonl"
    monkeypatch.setattr(latency, "_LOG_PATH", str(log))
    monkeypatch.setenv(
        "PYTEST_CURRENT_TEST", "tests/test_04.py::test_modify_propagation (call)"
    )

    latency.record("delivery", "E2E/Note.md", 1.23456)
    latency.record("file_gone", "E2E/Old.md", 0.4)

    lines = log.read_text().strip().split("\n")
    assert len(lines) == 2
    first = json.loads(lines[0])
    assert first["kind"] == "delivery"
    assert first["path"] == "E2E/Note.md"
    assert first["elapsed"] == 1.235
    # stage suffix "(call)" is stripped from the nodeid
    assert first["test"] == "tests/test_04.py::test_modify_propagation"


def test_record_never_raises_on_unwritable_path(monkeypatch):
    """Metric emission must never turn a green test red."""
    monkeypatch.setattr(latency, "_LOG_PATH", "/nonexistent-dir/report.jsonl")
    latency.record("delivery", "E2E/Note.md", 1.0)  # must not raise


def test_delivery_timeout_env_override(monkeypatch):
    """E2E_DELIVERY_TIMEOUT tunes the budget at import time."""
    import importlib

    monkeypatch.setenv("E2E_DELIVERY_TIMEOUT", "20")
    mod = importlib.reload(latency)
    try:
        assert mod.DELIVERY_TIMEOUT == 20.0
    finally:
        monkeypatch.delenv("E2E_DELIVERY_TIMEOUT")
        importlib.reload(latency)
