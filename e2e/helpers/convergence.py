"""Whole-folder convergence oracle: every device's disk equals the server, byte for byte.

Server bodies are the CRDT AUTHORITY (snapshot + update-log tail), not the
`notes.content` facade GET /notes serves; a failure also reports where the
two disagree.

The per-note waiters (`wait_for_content`, `wait_for_note_content`) prove a
marker arrived somewhere. They cannot see a duplicated paragraph, a stray
conflict copy, a resurrected file, or a device whose copy is a superset of the
server's. This compares the WHOLE test folder on every device against the
server and against an expectation, and names every offending path.

Scope: one folder PREFIX the test owns, on a private vault (see
docs/context/e2e-session-vault-scoping-trap.md for why vault-wide counts lie).

No sync is kicked while waiting. The devices must get there on their own
(live delivery, reconnect catch-up, the 1-minute periodic sync the harness
configures), because a real user does not run "Sync now" after every outage.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from helpers.authority_probe import authoritative_notes

logger = logging.getLogger(__name__)

# MCP get_notes reads at most 20 paths per call: one bulk read per 20 notes
# instead of one GET per note.
GET_NOTES_BATCH = 20


@dataclass
class Expect:
    """What the folder must hold once settled.

    notes:     path -> markers that must each appear EXACTLY once in that file.
    exact:     the folder's markdown paths must be exactly `notes`' keys
               (False when a test cannot predict every path, e.g. the soak).
    absent:    paths that must not exist anywhere (deleted, renamed away).
    at_most_once: markers that may be gone, but never appear twice in one note
               or in two notes.
    identities: one marker per logical note (its creation anchor). A note's
               identity in two non-copy files is ONE event, "note duplicated";
               the markers inside the extra file are not counted again.
    copy_ok:   body -> True when a "(conflict" copy holding that body is a
               legitimate outcome (keep-both from an edit racing a delete).

    Conflict copies are reported once each, as events; their bodies never
    count toward a marker's duplicates.
    """

    notes: dict[str, list[str]] = field(default_factory=dict)
    exact: bool = True
    absent: set[str] = field(default_factory=set)
    at_most_once: set[str] = field(default_factory=set)
    attachments: dict[str, bytes] = field(default_factory=dict)
    identities: set[str] = field(default_factory=set)
    copy_ok: Callable[[str], bool] | None = None


def _is_copy(path: str) -> bool:
    return "conflict" in path.lower()


def _vault_id(api) -> str:
    """The id of the api client's ONE vault (gauntlet users have exactly one)."""
    if not getattr(api, "_gauntlet_vault_id", None):
        vaults = api.list_vaults()
        assert len(vaults) == 1, f"convergence needs a single-vault user, got {len(vaults)}"
        api._gauntlet_vault_id = vaults[0]["id"]
    return api._gauntlet_vault_id


def server_state(api, prefix: str) -> tuple[dict[str, str], set[str]]:
    """(markdown path -> AUTHORITATIVE content, attachment paths) on the server.

    Note bodies come from `Notes.authoritative_content` (helpers/authority_probe),
    not from GET /notes or MCP get_notes: those read the `notes.content`
    facade, which lags every CRDT write until the next checkpoint.
    """
    manifest = api.get_manifest()
    attachments = {a["path"] for a in manifest.get("attachments", []) if a["path"].startswith(prefix)}
    notes = {p: t for p, t in authoritative_notes(_vault_id(api), prefix).items() if p.endswith(".md")}
    return notes, attachments


def facade_state(api, prefix: str) -> dict[str, str]:
    """markdown path -> the `notes.content` FACADE (what GET /notes serves).
    Diagnostic only: compared with the authority when a wait fails."""
    paths = sorted(n["path"] for n in api.get_manifest().get("notes", []) if n["path"].startswith(prefix))
    notes: dict[str, str] = {}
    for i in range(0, len(paths), GET_NOTES_BATCH):
        for n in api.mcp_tool("get_notes", {"paths": paths[i : i + GET_NOTES_BATCH]})["notes"]:
            if n.get("found") and "content" in n:
                notes[n["path"]] = n["content"]
    return notes


def disk_state(vault: Path, prefix: str) -> tuple[dict[str, str], dict[str, bytes]]:
    """(markdown path -> text, other file path -> bytes) on one device under prefix."""
    root = vault / prefix
    notes: dict[str, str] = {}
    others: dict[str, bytes] = {}
    if not root.exists():
        return notes, others
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(vault).as_posix()
        try:
            if p.suffix == ".md":
                notes[rel] = p.read_text(encoding="utf-8")
            else:
                others[rel] = p.read_bytes()
        except (FileNotFoundError, UnicodeDecodeError):
            continue  # mid-write or mid-delete; the next poll settles it
    return notes, others


def _first_diff(a: str, b: str) -> str:
    i = next((k for k, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    return f"at char {i}: server={a[max(0, i - 30) : i + 60]!r} disk={b[max(0, i - 30) : i + 60]!r}"


def problems(api, vaults: dict[str, Path], prefix: str, expect: Expect) -> list[str]:
    """Every way the folder is not converged right now. Empty means converged."""
    server, server_atts = server_state(api, prefix)
    out: list[str] = []

    every_path = set(server) | server_atts
    for name, vault in vaults.items():
        disk, others = disk_state(vault, prefix)
        every_path |= set(disk) | set(others)
        for path in sorted(set(server) ^ set(disk)):
            where = "server only" if path in server else "disk only"
            out.append(f"{name}: {path} {where}")
        for path in sorted(set(server) & set(disk)):
            if server[path] != disk[path]:
                out.append(f"{name}: {path} differs {_first_diff(server[path], disk[path])}")
        for path in sorted(server_atts ^ set(others)):
            out.append(f"{name}: attachment {path} {'server only' if path in server_atts else 'disk only'}")
        for path, data in expect.attachments.items():
            if others.get(path) != data:
                out.append(f"{name}: attachment {path} bytes wrong or missing")

    for p in sorted(p for p in every_path if _is_copy(p)):
        body = server.get(p)
        if not (expect.copy_ok and body is not None and expect.copy_ok(body)):
            out.append(f"conflict copy {p}")

    if expect.exact:
        for path in sorted(set(server) ^ set(expect.notes)):
            out.append(f"server {'has unexpected' if path in server else 'is missing'} {path}")
    for path in sorted(expect.absent & every_path):
        out.append(f"{path} should not exist")

    canonical = {p: b for p, b in server.items() if not _is_copy(p)}
    # One event per duplicated note; its extra files leave the marker count.
    extra: set[str] = set()
    for ident in sorted(expect.identities):
        files = sorted(p for p, b in canonical.items() if ident in b)
        if len(files) > 1:
            out.append(f"note duplicated: {ident!r} in {files}")
            keep = next((p for p in files if p in expect.notes), files[0])
            extra |= set(files) - {keep}
    counted = {p: b for p, b in canonical.items() if p not in extra}
    corpus = "\n".join(counted.values())
    for path, markers in expect.notes.items():
        body = server.get(path)
        if body is None:
            continue  # already reported as missing
        for m in markers:
            if (n := body.count(m)) != 1:
                out.append(f"{path}: marker {m!r} appears {n}x (want 1)")
            elif (total := corpus.count(m)) != 1:
                out.append(f"marker {m!r} appears {total}x across the folder (want 1)")
    for m in sorted(expect.at_most_once):
        if (n := corpus.count(m)) > 1:
            where = [p for p, b in counted.items() if m in b]
            out.append(f"marker {m!r} duplicated {n}x in {where}")
    return out


async def await_converged(
    api,
    vaults: dict[str, Path],
    prefix: str,
    expect: Expect,
    *,
    deadline_s: float = 240,
    poll_s: float = 3,
) -> float:
    """Wait until problems() is empty on two polls in a row; return seconds taken.

    Two in a row so a folder caught passing through the right state on its
    way to a wrong one (a late conflict copy, a resurrection) is not accepted.
    The deadline is a breakage bound, not a latency assertion.
    """
    start = time.monotonic()
    clean = 0
    found: list[str] = []
    while time.monotonic() - start < deadline_s:
        found = problems(api, vaults, prefix, expect)
        clean = clean + 1 if not found else 0
        if clean >= 2:
            took = time.monotonic() - start
            logger.warning("GAUNTLET converged %s in %.0fs", prefix, took)
            return took
        await asyncio.sleep(poll_s)
    # Name any path where the facade (GET /notes) and the authority disagree,
    # so a reader can tell "not checkpointed yet" from "lost".
    try:
        authority, _ = server_state(api, prefix)
        facade = facade_state(api, prefix)
        lag = sorted(p for p in authority if facade.get(p) != authority[p])
        found.insert(0, f"facade lags authority on {len(lag)} notes: {lag[:10]}")
    except Exception as e:  # noqa: BLE001 - diagnostics must not mask the real failure
        found.insert(0, f"facade comparison failed: {e!r}")
    shown = "\n  ".join(found[:60])
    more = f"\n  ... and {len(found) - 60} more" if len(found) > 60 else ""
    raise AssertionError(
        f"{prefix} did not converge within {deadline_s:.0f}s, {len(found)} problems:\n  {shown}{more}"
    )
