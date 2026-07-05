"""Unit tests for the vault wait helpers (helpers/vault.py).

Pure filesystem logic — no stack, no fixtures. Runs in CI via the "Harness
unit tests" step; locally:

    cd e2e/unit && python3 -m pytest test_vault.py -q
"""

from __future__ import annotations

import threading

import pytest

from helpers.vault import wait_for_file


def test_wait_for_file_returns_content(tmp_path):
    """Returns content once the file exists with a non-empty body."""
    rel = "E2E/Note.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("body", encoding="utf-8")

    assert wait_for_file(tmp_path, rel, timeout=1, poll=0.02) == "body"


def test_wait_for_file_skips_zero_byte_window(tmp_path):
    """A 0-byte file is the read-before-flush window — keep waiting, don't return "".

    Regression for the race behind intermittent `assert "x" in ""` failures:
    sync creates the file, then writes the body, and a bare exists() check
    returned "" in between.
    """
    rel = "E2E/Empty.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("", encoding="utf-8")

    with pytest.raises(TimeoutError):
        wait_for_file(tmp_path, rel, timeout=0.1, poll=0.02)


def test_wait_for_file_waits_past_empty_then_returns(tmp_path):
    """Empty first, body flushed a beat later → returns the body, not ""."""
    rel = "E2E/Late.md"
    full = tmp_path / rel
    full.parent.mkdir(parents=True)
    full.write_text("", encoding="utf-8")
    threading.Timer(0.1, full.write_text, args=("flushed",)).start()

    assert wait_for_file(tmp_path, rel, timeout=2, poll=0.02) == "flushed"
