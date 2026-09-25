"""Edits held while the CRDT socket is down reach the server on reconnect
WITHOUT a room per note (engram-app/Engram-obsidian#516, #537).

Before plugin #537, every doc whose live frame was refused while the socket
was down sat in an in-memory set, and every rejoin sent a STEP1 for each one:
one server room per held note, on every reconnect. The 2026-09-14 prod storm
matched that shape (~500 handshake rooms per minute from one device). Since
#537 the edit is recorded in the durable offline queue and delivered with
`crdt_doc_update`, which opens no room.

So this asserts two things, and both matter:
  1. every held edit reaches the server (the data guarantee the old
     re-enroll existed for, the "switch-away" class);
  2. the reconnects open ~no HANDSHAKE rooms for notes nobody has open.

The notes are never opened in an editor, so none of them is entitled to a
room. `read_room_starts()` counts allocation node-wide, so a little noise from
other activity is tolerated; the bound is a small fraction of NOTE_COUNT,
while the pre-#537 plugin allocates about one handshake room per note.
"""

import asyncio
import time

import pytest

from helpers.room_probe import arm_room_starts, read_room_starts
from helpers.vault import write_note

NOTE_COUNT = 40
FOLDER = "E2E/HeldEditRooms"
RECONNECTS = 2
# A small fraction of NOTE_COUNT: pre-#537 measures ~1 per note per rejoin.
HANDSHAKE_ROOM_BOUND = NOTE_COUNT // 8


def _path(i: int) -> str:
    return f"{FOLDER}/held{i:02d}.md"


async def _reconnect(cdp) -> None:
    await cdp.reconnect_stream()
    assert await cdp.check_stream_connected(), "reconnect_stream() must restore the channel"


@pytest.mark.asyncio
async def test_held_edits_deliver_without_a_room_per_note(vault_a, cdp_a, api_sync):
    try:
        # Baseline: every note synced while online, so each is a known server
        # note that is simply not open anywhere.
        for i in range(NOTE_COUNT):
            write_note(vault_a, _path(i), f"# Held {i}\n\nbase {i}")
        for i in range(NOTE_COUNT):
            api_sync.wait_for_note_content(_path(i), f"base {i}", timeout=60)

        await cdp_a.disconnect_stream()
        assert not await cdp_a.check_stream_connected(), (
            "disconnect_stream() must actually drop the channel"
        )
        try:
            for i in range(NOTE_COUNT):
                write_note(vault_a, _path(i), f"# Held {i}\n\nedited offline {i}")
            # Let the vault watcher see every write while the socket is down.
            await asyncio.sleep(3)

            # Arm AFTER the online baseline and the offline writes, so the
            # measured window is the reconnects alone.
            arm_room_starts()
            rooms_before = read_room_starts()
        finally:
            # MUST restore even on failure, or later tests inherit a dead socket.
            await _reconnect(cdp_a)

        # Every held edit reaches the server.
        for i in range(NOTE_COUNT):
            api_sync.wait_for_note_content(_path(i), f"edited offline {i}", timeout=60)

        # Further rejoins must not re-open rooms for notes nobody has open.
        for _ in range(RECONNECTS - 1):
            await cdp_a.disconnect_stream()
            await _reconnect(cdp_a)
        await asyncio.sleep(5)

        rooms = read_room_starts() - rooms_before
        print(f"\nheld-edit reconnect rooms for {NOTE_COUNT} idle notes: {rooms}")
        assert rooms.handshake <= HANDSHAKE_ROOM_BOUND, (
            f"{RECONNECTS} reconnects with {NOTE_COUNT} held idle edits opened "
            f"{rooms}. Notes that are not open in an editor must not get a room; "
            "pre-#537 this was one handshake room per held note per rejoin "
            "(engram-app/Engram-obsidian#516)."
        )
    finally:
        manifest = api_sync.get_manifest()
        ids = [
            n["id"]
            for n in manifest.get("notes", [])
            if n.get("id") and n.get("path", "").startswith(f"{FOLDER}/")
        ]
        if ids:
            api_sync.batch_delete_notes(ids)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not await cdp_a.check_stream_connected():
            await asyncio.sleep(0.5)
