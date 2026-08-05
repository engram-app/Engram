"""Delivery oracle: wait for a synced file AND, on timeout, mine the client
log stream (GET /logs) to report WHERE the sync causal chain broke.

Drop-in superset of ``wait_for_file`` for cross-instance delivery asserts.
On success it behaves identically (polls the receiver's vault, returns file
content, never touches the network). On timeout it queries
``api_sync.get_logs()`` and classifies the receiver's client logs for the
path so the failure names the gap instead of stalling blindly:

    received     -> a "channel"/"ws" log line: "Event: ... <path>"
    materialized -> a "vault" log line: "create|modify path=<path> bytes=N"

A blank "file did not appear in 120s" becomes, e.g.,
"received=yes materialized=no" (server delivered, client never wrote) or
"received=no materialized=no" (never reached the client at all) — or, the
case that motivated the byte tracking below, "received=yes materialized=yes
last_write=0B", meaning the client DID write the path and the last thing it
wrote there was empty.

Attribution: every log entry carries its originating device (the plugin
stamps ``device_id`` in ``remote-log.ts``; the backend persists it on
``client_log`` and returns it from ``GET /logs``). The receiver's own id is
read straight out of the vault we are already polling —
``<vault>/.obsidian/plugins/engram-vault-sync/data.json`` — so no fixture
plumbing is needed. When it resolves, only that device's lines are
classified; when it does not, we fall back to the historical category
heuristic (the origin instance logs under "push", the receiver under
"pull"/"ws"/"channel"), which is right for "A creates / B receives" but
silently wrong wherever both instances touch the same path. The failure
message says which mode was used, so a misleading verdict is self-evident.

Why "vault" rather than the old ("Created:", "Applied:") prefixes: those are
signatures of the REST pull path only. A note materialized through a CRDT
binding never matches them, so on a CRDT-managed note the oracle reported
``materialized=no`` even when the file HAD been written — it was blind on
exactly the suites that need it most. The "vault" category comes from
``diagnostics.ts``, which listens to Obsidian's own vault events, so it
observes the FILESYSTEM and is agnostic to which code path did the write. It
also carries ``bytes=``, which is what separates "never written" from
"written, then clobbered to empty" — the 0-byte folder-rename failure in
test_34 is invisible under a boolean materialized flag, and cost a long
manual log dig to spot.

Log-line signatures verified against plugin src on 2026-08-05:
  channel.ts:456      rlog().info("channel", `Event: ${type} ${path}`)
  sync.ts:1992        rlog().info("ws", `Event: ${type} note: ${path}`)
  diagnostics.ts:34   rlog().diag("vault", "create path=<p> bytes=<n>")
  diagnostics.ts:34   rlog().diag("vault", "modify path=<p> bytes=<n>")
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from helpers.latency import DELIVERY_TIMEOUT

_RECEIVE_CATEGORIES = ("channel", "ws")
_VAULT_CATEGORY = "vault"
# Classic REST pull-path materialize signatures. Still valid — a note pulled
# over REST logs these — they are just not SUFFICIENT, since a CRDT-bound
# materialize emits neither.
_REST_MATERIALIZE_CATEGORY = "pull"
_NOTE_MATERIALIZE = ("Created:", "Applied:")
# Attachments still materialize through the REST pull path (binary bodies are
# not CRDT-managed), so their prefixes remain a valid signal.
_ATTACHMENT_MATERIALIZE = ("Attachment applied:", "Attachment created:")

_PLUGIN_ID = "engram-vault-sync"
# "create path=E2E/x.md bytes=22" / "modify path=E2E/x.md bytes=0"
_VAULT_WRITE_RE = re.compile(
    r"^(?:create|modify) path=(?P<path>.+?) bytes=(?P<bytes>\d+)$"
)


def _yn(flag: bool) -> str:
    return "yes" if flag else "no"


def receiver_device_id(vault_path) -> str | None:
    """The deviceId the plugin persisted for the instance owning ``vault_path``.

    ``main.ts`` generates it once with ``crypto.randomUUID()`` and stores it in
    the plugin's data.json, so it is stable for the life of the instance.
    Best-effort by design: this only sharpens a diagnostic, so an absent or
    unreadable data.json must degrade to "unknown" rather than raise into an
    already-failing test.
    """
    p = Path(vault_path) / ".obsidian" / "plugins" / _PLUGIN_ID / "data.json"
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("deviceId") or None
    except Exception:  # noqa: BLE001 - diagnostic enrichment, see docstring
        return None


def _classify(
    logs: list[dict],
    rel_path: str,
    *,
    device_id: str | None,
    attachment: bool,
) -> tuple[bool, bool, int | None, list[str]]:
    """Scan client logs for the path.

    Returns ``(received, materialized, last_write_bytes, hits)``.
    ``last_write_bytes`` is the byte count of the final "vault" create/modify
    seen for the path, or None for attachments and when no vault line matched.
    """
    received = False
    materialized = False
    last_bytes: int | None = None
    hits: list[str] = []

    for log in logs:
        message = log.get("message", "")
        if rel_path not in message:
            continue
        # Device filter, when we know who we are. Without it a two-instance test
        # mixes the SENDER's writes into the receiver's evidence — which is how
        # a "bytes=22" logged by A can make B's empty file look healthy.
        if device_id and log.get("device_id") and log.get("device_id") != device_id:
            continue

        category = log.get("category", "")
        hits.append(f"{category}: {message}")

        if category in _RECEIVE_CATEGORIES and "Event:" in message:
            received = True

        if attachment:
            if category == "pull" and message.startswith(_ATTACHMENT_MATERIALIZE):
                materialized = True
            continue

        # The REST-pull signatures are KEPT alongside the vault-event signal,
        # not replaced by it. "vault" only flows while diagnosticsEnabled is on,
        # so dropping these would trade one blind spot for another; together
        # they are a strict superset of the old behaviour.
        if category == _REST_MATERIALIZE_CATEGORY and message.startswith(
            _NOTE_MATERIALIZE
        ):
            materialized = True

        if category == _VAULT_CATEGORY:
            m = _VAULT_WRITE_RE.match(message)
            # Compare the PARSED path, not a substring: `rel_path in message`
            # also matches a longer sibling that merely contains it.
            if m and m.group("path") == rel_path:
                materialized = True
                last_bytes = int(m.group("bytes"))

    return received, materialized, last_bytes, hits


def _timeout_error(
    rel_path: str,
    api_sync,
    timeout: float,
    *,
    vault_path=None,
    attachment: bool = False,
) -> TimeoutError:
    """Build a causal-chain TimeoutError from the client log stream.

    Best-effort diagnostics on an ALREADY-failed wait: a log-query error must
    not mask the real timeout, so we fold it into the message rather than let
    it propagate and hide what actually failed.
    """
    received = materialized = False
    last_bytes: int | None = None
    hits: list[str] = []
    device_id = receiver_device_id(vault_path) if vault_path is not None else None
    try:
        logs = api_sync.get_logs(limit=200).get("logs", [])
        received, materialized, last_bytes, hits = _classify(
            logs, rel_path, device_id=device_id, attachment=attachment
        )
    except Exception as exc:  # noqa: BLE001 - diagnostic enrichment, see docstring
        hits = [f"(log query failed: {exc})"]

    who = (
        f"device={device_id[:8]}"
        if device_id
        else "device=UNKNOWN (fell back to the category heuristic — "
        "evidence below may include the OTHER instance's lines)"
    )
    tail = ""
    if last_bytes is not None:
        tail = f" last_write={last_bytes}B"
        if last_bytes == 0:
            # The whole reason this oracle tracks bytes: "wrote the path, then
            # wrote nothing over it" is a different bug from "never wrote it",
            # and a boolean materialized flag reports them identically.
            tail += " <- WROTE THE PATH THEN LEFT IT EMPTY (not a delivery gap)"

    detail = "\n  ".join(hits) if hits else "(no client log line mentioned the path)"
    return TimeoutError(
        f"{rel_path} not delivered within {timeout}s [{who}]. "
        f"Client-log evidence: received={_yn(received)} "
        f"materialized={_yn(materialized)}{tail}.\n  {detail}"
    )


def wait_for_delivery(
    vault_path,
    rel_path: str,
    api_sync,
    timeout: float = DELIVERY_TIMEOUT,
    poll: float = 0.3,
) -> str:
    """Poll until ``rel_path`` materializes in ``vault_path``, return its text.

    On timeout, raise TimeoutError whose message names the causal-chain gap,
    mined from ``api_sync.get_logs()``.
    """
    full = Path(vault_path) / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        # Non-empty guard matches wait_for_binary_delivery: sync creates the
        # file then writes the body, so a bare exists() check can return "" in
        # the 0-byte window (the read-before-flush race). Returning "" makes the
        # caller's substring assert fail WITHOUT this oracle's causal-chain
        # diagnostic ever firing — so wait past the empty window like the
        # binary variant does.
        if full.exists() and full.stat().st_size > 0:
            return full.read_text(encoding="utf-8")
        time.sleep(poll)
    raise _timeout_error(rel_path, api_sync, timeout, vault_path=vault_path)


def wait_for_binary_delivery(
    vault_path,
    rel_path: str,
    api_sync,
    timeout: float = DELIVERY_TIMEOUT,
    poll: float = 0.3,
) -> bytes:
    """Attachment variant of ``wait_for_delivery``.

    Waits for a non-empty binary file (a 0-byte placeholder is not delivered),
    returns its bytes, and on timeout mines the log stream using the
    attachment materialize signatures ("Attachment applied/created:").
    """
    full = Path(vault_path) / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if full.exists() and full.stat().st_size > 0:
            return full.read_bytes()
        time.sleep(poll)
    raise _timeout_error(
        rel_path, api_sync, timeout, vault_path=vault_path, attachment=True
    )


def wait_for_client_log(
    api_sync, *needles: str, timeout: float, after: str | None = None
) -> None:
    """Poll client logs until one line contains ALL ``needles``.

    Shared by CRDT mechanism-oracle tests (previously duplicated as a local
    ``_wait_for_log``/``_wait_for_heal_log`` in each test file). Logs
    aggregate across every device sharing the harness's client_id, so scope
    with a path needle where only one device's line is valid.

    ``after`` is an ISO 8601 timestamp, forwarded to ``GET /logs?since=``
    (``LogsController``/``Logs.list_logs`` filter on the log's client-supplied
    ``ts``, strictly greater-than). Pass a baseline captured right after
    staging a wedge so a line logged BEFORE the wedge — e.g. an unrelated
    open-heal that happens to match the same needles — can't satisfy the
    wait. Omit it for an id-agnostic, window-agnostic wait (matches any line
    ever logged).
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        logs = api_sync.get_logs(since=after or "", limit=1000).get("logs", [])
        if any(all(n in log.get("message", "") for n in needles) for log in logs):
            return
        time.sleep(1)
    raise TimeoutError(f"no client log containing {needles!r} within {timeout}s")
