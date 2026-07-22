"""Delivery budget + per-run latency metric (determinism decision, 2026-07-22).

Correctness asserts wait on the observable event (file/note materializing)
under ONE generous budget that only expires on true breakage. How long the
wait actually took is recorded as a metric, never asserted per-test: the old
8-30s budgets were performance assertions wearing correctness costumes — the
same SHA passed and failed depending on runner load.

Every successful wait appends one JSON line to ``E2E_LATENCY_LOG`` (default
``latency-report.jsonl`` in the pytest cwd). Append-per-record means xdist
workers need no coordination, and a crashed/hung run keeps every record up to
the crash. CI uploads the file unconditionally; trend analysis happens
offline and never gates a single test.
"""

from __future__ import annotations

import json
import os
import time

DELIVERY_TIMEOUT = float(os.environ.get("E2E_DELIVERY_TIMEOUT", "120"))

_LOG_PATH = os.environ.get("E2E_LATENCY_LOG", "latency-report.jsonl")


def record(kind: str, rel_path: str, elapsed: float) -> None:
    """Append one latency record. Diagnostic-only; must never fail a test."""
    entry = {
        "t": round(time.time(), 3),
        # pytest sets PYTEST_CURRENT_TEST to "<nodeid> (<stage>)"
        "test": os.environ.get("PYTEST_CURRENT_TEST", "").split(" ")[0],
        "kind": kind,
        "path": rel_path,
        "elapsed": round(elapsed, 3),
    }
    try:
        with open(_LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass  # metric emission must never turn a green test red
