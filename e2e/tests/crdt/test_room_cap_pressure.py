"""Convergence under resident-room pressure.

The existing CRDT suite converges one or two notes at a time, so it never puts
more concurrently-diverged cold notes in flight than `CRDT_MAX_RESIDENT_ROOMS`
(3 in `ci/compose.yml`). A 1,192-note vault on 2026-08-29 did, and stopped
converging in BOTH directions: 1,125 distinct doc_ids requested a room against a
cap of 64, residency overshot to 196 with a backlog of 116, and the LRU evicted
16 rooms at a time while clients were still handshaking them.

The client has an escape hatch for exactly this — `convergeColdNoteRoomFree`
(sync.ts) reads `crdt_doc_state` and merges without a room. It is gated on
`!hasUndeliveredOps(noteId)`, which is TRUE for any note whose provider is still
holding work. So a note that fails to deliver through an evicted room keeps its
undelivered ops, stays locked out of the room-free path, and asks for another
room. That is a closed loop, and it is self-reinforcing under pressure.

These tests put more cold notes in flight than the cap and assert every one of
them lands. They are deliberately about the FLEET, not about any single note:
one note at a time converges fine today, which is why this class survived.
"""

from __future__ import annotations

import os

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content, write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = DELIVERY_TIMEOUT

# Ratio to `CRDT_MAX_RESIDENT_ROOMS` (3 in ci/compose.yml) matters more than the
# absolute count: the 2026-08-29 vault ran ~18x the cap (1,192 notes / 64) and
# overshot residency to 196 with a 116 backlog, so allocation was outrunning the
# drain. 12 (4x) was tried first and both tests passed, which is why this is 54.
FLEET = 54


def _fleet_paths(tag: str) -> list[str]:
    return [f"E2E/Crdt/RoomCap/{tag}{i:02d}.md" for i in range(FLEET)]


def _establish_fleet(vault_a, vault_b, api_sync, paths: list[str]) -> None:
    """Create every path on A and wait until all of them exist on B.

    Written as write-all-then-wait-all rather than per-note establish: the point
    is to get FLEET notes into a shared base cheaply, and serialising a delivery
    wait per note triples the setup cost for no extra coverage.
    """
    for i, path in enumerate(paths):
        write_note(vault_a, path, f"base {i}\n")
    for i, path in enumerate(paths):
        api_sync.wait_for_note_content(path, f"base {i}", timeout=CRDT_TIMEOUT)
        wait_for_content(vault_b, path, f"base {i}", timeout=CRDT_TIMEOUT)


@pytest.mark.asyncio
async def test_cold_fleet_larger_than_room_cap_all_converge(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """[P1] FLEET cold notes diverge at once, FLEET > the resident-room cap.
    EVERY one must reach B.

    No note is open in an editor, so each one is a cold convergence. If the
    room-free path is doing its job the cap is irrelevant; if each note needs a
    room, the cap is exceeded by 4x and the LRU starts evicting rooms that
    clients are still using.

    Asserts on the whole fleet and reports which paths were lost — a single-note
    assertion would pass on a partial convergence, which is exactly the shape
    that shipped.
    """
    paths = _fleet_paths("cold")
    _establish_fleet(vault_a, vault_b, api_sync, paths)

    for i, path in enumerate(paths):
        write_note(vault_a, path, f"base {i}\nCOLD_FLEET_{i}\n")

    missing = []
    for i, path in enumerate(paths):
        try:
            content = wait_for_content(vault_b, path, f"COLD_FLEET_{i}", timeout=CRDT_TIMEOUT)
            if f"base {i}" not in content:
                missing.append(f"{path} (base lost)")
        except Exception as exc:  # noqa: BLE001 — collect, do not abort the sweep
            missing.append(f"{path} ({type(exc).__name__})")

    assert not missing, (
        f"{len(missing)}/{FLEET} cold notes never converged on B under room-cap "
        f"pressure: {missing}"
    )


@pytest.mark.asyncio
async def test_edits_still_send_after_a_cold_fleet_burst(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """[P1] After a fleet burst has exhausted the room cap, A can still SEND.

    The 2026-08-29 report was that Obsidian went inert in BOTH directions, not
    just that it stopped receiving. If undelivered ops pin providers open and the
    room path is saturated, the send half dies too — so this asserts the sender
    recovers once the burst has settled, on a note that took part in the burst.
    """
    paths = _fleet_paths("send")
    _establish_fleet(vault_a, vault_b, api_sync, paths)

    for i, path in enumerate(paths):
        write_note(vault_a, path, f"base {i}\nBURST_{i}\n")

    # Let the burst settle as far as it is going to.
    target = paths[0]
    wait_for_content(vault_b, target, "BURST_0", timeout=CRDT_TIMEOUT)

    # A fresh edit, AFTER the pressure event, on a note that was part of it.
    write_note(vault_a, target, "base 0\nBURST_0\nAFTER_THE_BURST\n")
    content = wait_for_content(vault_b, target, "AFTER_THE_BURST", timeout=CRDT_TIMEOUT)
    assert "BURST_0" in content, f"burst edit lost by the follow-up send: {content!r}"
