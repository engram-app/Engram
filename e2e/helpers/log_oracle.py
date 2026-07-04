"""Delivery oracle: wait for a synced file AND, on timeout, mine the client
log stream (GET /logs) to report WHERE the sync causal chain broke.

Drop-in superset of ``wait_for_file`` for cross-instance delivery asserts.
On success it behaves identically (polls the receiver's vault, returns file
content, never touches the network). On timeout it queries
``api_sync.get_logs()`` and classifies the receiver's client logs for the
path so the failure names the gap instead of stalling blindly:

    received     -> a "channel"/"ws" log line: "Event: ... <path>"
    materialized -> a "pull" log line: "Created: <path>" / "Applied: <path>"

A blank "file did not appear in 30s" becomes, e.g.,
"received=yes materialized=no" (server delivered, client never wrote) or
"received=no materialized=no" (never reached the client at all).

Attribution note: e2e ``vault_a`` and ``vault_b`` share one user AND one
client_id, so client_logs carry no per-instance field. We disambiguate the
RECEIVER by category (the origin instance logs under "push"; the receiver
logs under "pull"/"ws"/"channel") plus the path in the message. That holds
for "A creates / B receives" delivery tests where B is the sole
materializer. Once client_logs gains a device_id (tracked separately) the
oracle can key on the instance directly.

Log-line signatures verified against plugin src on 2026-07-04:
  channel.ts:456  rlog().info("channel", f"Event: {type} {path}")
  sync.ts:1992    rlog().info("ws", f"Event: {type} note: {path}")
  sync.ts:2582    rlog().info("pull", f"Applied: {path} | ...")
  sync.ts:2608    rlog().info("pull", f"Created: {path} | len=...")
"""

from __future__ import annotations

import time
from pathlib import Path

_RECEIVE_CATEGORIES = ("channel", "ws")
_MATERIALIZE_CATEGORY = "pull"
_MATERIALIZE_PREFIXES = ("Created:", "Applied:")


def _yn(flag: bool) -> str:
    return "yes" if flag else "no"


def _classify(logs: list[dict], rel_path: str) -> tuple[bool, bool, list[str]]:
    """Scan client logs for the path. Return (received, materialized, hits)."""
    received = False
    materialized = False
    hits: list[str] = []
    for log in logs:
        message = log.get("message", "")
        if rel_path not in message:
            continue
        category = log.get("category", "")
        hits.append(f"{category}: {message}")
        if category in _RECEIVE_CATEGORIES and "Event:" in message:
            received = True
        if category == _MATERIALIZE_CATEGORY and message.startswith(_MATERIALIZE_PREFIXES):
            materialized = True
    return received, materialized, hits


def wait_for_delivery(
    vault_path, rel_path: str, api_sync, timeout: float = 30, poll: float = 0.3
) -> str:
    """Poll until ``rel_path`` materializes in ``vault_path``, return its content.

    On timeout, raise TimeoutError whose message names the causal-chain gap,
    mined from ``api_sync.get_logs()``.
    """
    full = Path(vault_path) / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if full.exists():
            return full.read_text(encoding="utf-8")
        time.sleep(poll)

    # Timed out. Enrich with the client-log causal chain. This is best-effort
    # diagnostics on an ALREADY-failed wait: a log-query error must not mask
    # the real TimeoutError, so we swallow it into the message rather than let
    # it propagate and hide what actually failed.
    received = materialized = False
    hits: list[str] = []
    try:
        logs = api_sync.get_logs(limit=200).get("logs", [])
        received, materialized, hits = _classify(logs, rel_path)
    except Exception as exc:  # noqa: BLE001 - diagnostic enrichment, see comment above
        hits = [f"(log query failed: {exc})"]

    detail = "\n  ".join(hits) if hits else "(no client log line mentioned the path)"
    raise TimeoutError(
        f"{rel_path} not delivered within {timeout}s. "
        f"Client-log evidence: received={_yn(received)} "
        f"materialized={_yn(materialized)}.\n  {detail}"
    )
