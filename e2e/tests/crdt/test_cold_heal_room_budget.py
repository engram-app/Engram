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
import math
import os
import time
import uuid

import pytest

from helpers.room_probe import arm_room_starts, read_room_starts

logger = logging.getLogger(__name__)

# Enough diverged notes that a room per note is unmistakable next to the budget,
# small enough to keep the e2e-crdt job's wall clock sane.
NOTE_COUNT = int(os.environ.get("E2E_COLD_HEAL_NOTE_COUNT", "300"))

# The fix's per-device start budget (Engram-obsidian#644: token bucket, burst 5
# then 15 a minute). Two devices hold this user's vault (A and B), so the bound
# allows both, even though only A's socket drops.
BURST = 5
RATE_PER_MIN = 15
DEVICES = 2

# Independent of how long convergence takes: a room per note is O(N), the fix
# is O(1). Without this, a slow enough red run would earn its way under the
# time-scaled bucket bound.
HARD_CEILING = NOTE_COUNT // 4

CONVERGE_TIMEOUT_S = 6 * 60
NO_PROGRESS_KICK_S = 30
# Rooms a trailing heal opens after the last file lands still count.
SETTLE_S = 15


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


def _cleanup(api_sync, folder: str) -> None:
    ids = [
        n["id"]
        for n in api_sync.get_manifest().get("notes", [])
        if n.get("id") and n.get("path", "").startswith(folder)
    ]
    for start in range(0, len(ids), 500):
        status = api_sync.batch_delete_notes(ids[start : start + 500])
        assert status < 300, f"cold-heal cleanup: batch-delete returned {status}"


@pytest.mark.timeout(20 * 60)
@pytest.mark.asyncio
async def test_resume_cold_heals_stay_in_room_budget(vault_a, cdp_a, api_sync, capsys):
    run = uuid.uuid4().hex[:8]
    folder = f"ColdHeal-{run}/"
    paths = [f"{folder}n{i:04d}.md" for i in range(NOTE_COUNT)]
    disconnected = False
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
        disconnected = True
        assert not await cdp_a.check_stream_connected(), "socket did not drop"
        for i, p in enumerate(paths):
            api_sync.create_note(p, _content(i, run, 2))

        arm_room_starts()
        before = read_room_starts()
        started = time.monotonic()
        await cdp_a.reconnect_stream()
        disconnected = False
        converged_s = await _wait_converged(
            vault_a, cdp_a, paths, run, 2, CONVERGE_TIMEOUT_S
        )
        await asyncio.sleep(SETTLE_S)
        rooms = read_room_starts() - before
        elapsed_min = (time.monotonic() - started) / 60

        budget = DEVICES * (BURST + math.ceil(RATE_PER_MIN * elapsed_min))
        bound = min(budget, HARD_CEILING)
        # Uncaptured so a green run records its count too (the red/green proof).
        with capsys.disabled():
            print(
                f"\ncold-heal: {NOTE_COUNT} diverged notes converged in {converged_s:.1f}s; "
                f"resume window {elapsed_min:.2f} min allocated {rooms}; "
                f"handshake bound {bound} (bucket {budget}, ceiling {HARD_CEILING})"
            )
        assert rooms.handshake <= bound, (
            f"resume heal of {NOTE_COUNT} diverged cold notes opened "
            f"{rooms.handshake} handshake rooms in {elapsed_min:.2f} min, past the "
            f"bound {bound} ({DEVICES} devices x (burst {BURST} + {RATE_PER_MIN}/min), "
            f"capped at N/4). A room per diverged note is the Engram#2242 surge: "
            f"cold heals must go room-free or through the pooled, rate-capped path."
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
        if disconnected:
            await cdp_a.reconnect_stream()
        try:
            _cleanup(api_sync, folder)
        except Exception:
            logger.exception("cold-heal cleanup failed; %s residue may leak", folder)
            raise
