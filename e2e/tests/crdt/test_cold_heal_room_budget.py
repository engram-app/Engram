"""Cold-note heals after a socket resume stay inside the per-device room budget.

The prod "CRDT handshake room surge" (Engram#2242, Engram-obsidian#623): one
desktop logged `CRDT catch-up: diverged cold note, socket re-handshake n6291`
and a task hit 337 handshake rooms in 2 minutes. Plugin 1.38.1 read "has this
doc got undelivered ops?" from the in-memory handshake `synced` flag, which a
disconnect wipes (`clearSynced`). So after a resume every resident idle doc
looked undelivered, `convergeColdNoteRoomFree` refused the room-free read, and
each diverged cold note fell to `socketConverge` -> `fireCrdtReHandshake`: one
server room per note, no cap.

The fix (Engram-obsidian#644, release 1.39.0) persists a server-acked mark so
those notes converge room-free, and caps whatever still needs a room behind a
4-slot pool and a per-device token bucket (burst 5, then 15 a minute).

Stage: N server-created notes sync into device A with none open in an editor,
one round of server edits lands live (so their docs are resident), then A's
socket drops, every note is edited again server-side, and the socket resumes.
Catch-up must heal all N. Asserted:

* handshake-source room starts over the resume window stay within the fix's
  budget (1.38.1 opens roughly one per diverged note);
* every note on A's disk converges to the server's latest content (no loss).

Rooms are counted by allocation (`room_probe`), not residency: the CI drain
(`CRDT_IDLE_EXIT_MS`) sheds a burst between two samples.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import time
import uuid

import pytest

from helpers.room_probe import arm_room_starts, read_room_starts

logger = logging.getLogger(__name__)

# Enough diverged notes that a room per note is unmistakable next to the budget,
# small enough to keep the e2e-crdt job's wall clock sane.
NOTE_COUNT = int(os.environ.get("E2E_COLD_HEAL_NOTE_COUNT", "300"))
# An override of 0 (or a handful) would make every assertion below vacuous.
MIN_NOTE_COUNT = 50

# The fix's per-device start budget (Engram-obsidian#644: token bucket, burst 5
# then 15 a minute). Only device A holds the vault here: obsidian_b is a lazy
# session fixture and this file sorts first in tests/crdt/, so B never runs.
BURST = 5
DEVICES = 1
# The probe counts room ALLOCATIONS, not heal tokens. One heal allocates about
# two: the handshake room, then a restart after the CI idle drain
# (CRDT_IDLE_EXIT_MS) closes it. Measured: 1.38.1 allocated 600 for 300 heals.
ALLOCS_PER_HEAL = 2

# Fixed, independent of N and of wall clock: the fix's claim is O(1) rooms for
# O(N) diverged notes. A time-scaled bound lets a slow or partial regression
# (dozens of notes each falling back to a room) earn its way under it. Green
# measured 10 (one burst at two allocations per heal); the slack absorbs one
# extra burst and incidental live-bound handshakes.
ROOM_CEILING = DEVICES * ALLOCS_PER_HEAL * BURST + 15

CONVERGE_TIMEOUT_S = 6 * 60
NO_PROGRESS_KICK_S = 30
# Rooms a trailing heal opens after the last file lands still count.
SETTLE_S = 15
CLEANUP_TIMEOUT_S = 120


def _content(i: int, run: str, round_: int) -> str:
    return f"# Cold heal {i}\n\nrun {run} round {round_} body {i}\n"


def _marker(i: int, run: str, round_: int) -> str:
    return f"run {run} round {round_} body {i}"


def _pending(vault, paths: list[str], run: str, round_: int) -> list[int]:
    """Indexes whose file on disk does not yet hold this round's body."""
    out = []
    for i, p in enumerate(paths):
        f = vault / p
        try:
            if _marker(i, run, round_) not in f.read_text(encoding="utf-8"):
                out.append(i)
        except FileNotFoundError:
            out.append(i)
    return out


async def _wait_converged(vault, cdp, paths, run, round_, timeout) -> float:
    """Poll disk until every note holds `round_`. Kick a catch-up on a stall."""
    started = time.monotonic()
    last_left, last_progress = None, started
    while True:
        left = _pending(vault, paths, run, round_)
        now = time.monotonic()
        if not left:
            return now - started
        if left != last_left:
            last_left, last_progress = left, now
        elif now - last_progress >= NO_PROGRESS_KICK_S:
            await cdp.trigger_catch_up()
            last_progress = now
        if now - started >= timeout:
            raise AssertionError(
                f"{len(left)}/{len(paths)} notes never converged to round {round_} "
                f"within {timeout}s (first: {[paths[i] for i in left[:5]]})"
            )
        await asyncio.sleep(1)


async def _ensure_connected(cdp) -> None:
    """Bring A's socket back if it is down. `reconnect_stream` only logs on failure."""
    if not await cdp.check_stream_connected():
        await cdp.reconnect_stream()
    # Raises with the channel diagnosis if the socket never comes back.
    await cdp.wait_for_stream_connected()


async def _cleanup(api_sync, vault, folder: str) -> None:
    """Delete this test's notes and wait until A has applied every delete.

    This file sorts first in tests/crdt/ and the session vault is shared, so
    returning before A drains 300 deletes would bleed that work into the
    measurements of every test after it.
    """
    ids = [
        n["id"]
        for n in api_sync.get_manifest().get("notes", [])
        if n.get("id") and n.get("path", "").startswith(folder)
    ]
    for start in range(0, len(ids), 500):
        status = api_sync.batch_delete_notes(ids[start : start + 500])
        assert status < 300, f"cold-heal cleanup: batch-delete returned {status}"

    local = vault / folder
    left: list = []
    deadline = time.monotonic() + CLEANUP_TIMEOUT_S
    while time.monotonic() < deadline:
        left = list(local.glob("*.md")) if local.exists() else []
        if not left:
            break
        await asyncio.sleep(1)
    assert not left, f"cold-heal cleanup: A still holds {len(left)} files in {folder}"
    shutil.rmtree(local, ignore_errors=True)


@pytest.mark.timeout(20 * 60)
@pytest.mark.asyncio
async def test_resume_cold_heals_stay_in_room_budget(vault_a, cdp_a, api_sync, capsys):
    assert NOTE_COUNT >= MIN_NOTE_COUNT, (
        f"E2E_COLD_HEAL_NOTE_COUNT={NOTE_COUNT} is below {MIN_NOTE_COUNT}; "
        "the room bound would be vacuous"
    )
    run = uuid.uuid4().hex[:8]
    folder = f"ColdHeal-{run}/"
    paths = [f"{folder}n{i:04d}.md" for i in range(NOTE_COUNT)]
    try:
        await cdp_a.wait_for_stream_connected()

        # Round 0: server-created, discovered by A. Nothing opens them in an editor.
        for i, p in enumerate(paths):
            api_sync.create_note(p, _content(i, run, 0))
        await _wait_converged(vault_a, cdp_a, paths, run, 0, CONVERGE_TIMEOUT_S)

        # Round 1: live server edits make the docs resident on A.
        for i, p in enumerate(paths):
            api_sync.create_note(p, _content(i, run, 1))
        await _wait_converged(vault_a, cdp_a, paths, run, 1, CONVERGE_TIMEOUT_S)

        # Drop A's socket (1.38.1 wipes every resident doc's `synced` flag here),
        # then diverge every note server-side while A cannot hear it.
        await cdp_a.disconnect_stream()
        assert not await cdp_a.check_stream_connected(), "socket did not drop"
        # Armed before the offline writes: if A reconnects on its own mid-write,
        # the heal it starts is still counted. The counter is node-global (any
        # vault, any user); that is safe only because e2e-crdt runs serially.
        arm_room_starts()
        before = read_room_starts()
        started = time.monotonic()
        for i, p in enumerate(paths):
            api_sync.create_note(p, _content(i, run, 2))
        assert not await cdp_a.check_stream_connected(), (
            "A reconnected on its own during the offline writes"
        )

        await cdp_a.reconnect_stream()
        await cdp_a.wait_for_stream_connected()
        converged_s = await _wait_converged(
            vault_a, cdp_a, paths, run, 2, CONVERGE_TIMEOUT_S
        )
        await asyncio.sleep(SETTLE_S)
        rooms = read_room_starts() - before
        elapsed_min = (time.monotonic() - started) / 60

        # Uncaptured so a green run records its count too (the red/green proof).
        with capsys.disabled():
            print(
                f"\ncold-heal: {NOTE_COUNT} diverged notes converged in {converged_s:.1f}s; "
                f"window {elapsed_min:.2f} min allocated {rooms}; ceiling {ROOM_CEILING}"
            )
        # Total, not handshake only: a heal re-routed through a path tagged
        # `edit` or `unknown` is the same surge.
        assert rooms.total <= ROOM_CEILING, (
            f"resume heal of {NOTE_COUNT} diverged cold notes allocated {rooms} in "
            f"{elapsed_min:.2f} min, past the fixed ceiling {ROOM_CEILING}. A room per "
            "diverged note is the Engram#2242 surge: cold heals must go room-free or "
            "through the pooled, rate-capped path."
        )

        # No data loss: the server still holds the round-2 body for every note
        # (disk convergence above is the client half).
        stale = [
            p
            for i, p in enumerate(paths)
            if _marker(i, run, 2)
            not in ((api_sync.get_note(p) or {}).get("content") or "")
        ]
        assert not stale, f"{len(stale)} notes lost their server content: {stale[:5]}"
    finally:
        try:
            await _ensure_connected(cdp_a)
            await _cleanup(api_sync, vault_a, folder)
        except Exception:
            logger.exception("cold-heal cleanup failed; %s residue may leak", folder)
            raise
