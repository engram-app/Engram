"""Bulk vault operations and the room-start budget for the release-gauntlet tests.

Every device-side write goes through Obsidian's vault API in ONE CDP call per
batch (not one evaluate per file), so a 1,000-note setup is a handful of round
trips and the plugin sees the same `create`/`modify`/`rename`/`delete` events
a user's edits fire.
"""

from __future__ import annotations

import json
import logging
import math
import time
from concurrent.futures import ThreadPoolExecutor

from helpers.room_probe import RoomStarts, arm_room_starts, read_room_starts

logger = logging.getLogger(__name__)

# Notes per evaluate. Big enough to keep round trips low, small enough that
# one batch stays far under CdpClient.evaluate's 120s ceiling on a slow runner.
_BATCH = 100

# Engram-obsidian#644 heal-room start budget, per device: a token bucket with
# burst 5 refilling 15 a minute (HEAL_ROOM_BURST / HEAL_ROOMS_PER_MINUTE in
# src/sync.ts), so any 60 s window holds at most 20 starts.
HEAL_ROOM_BURST = 5
HEAL_ROOMS_PER_MINUTE = 15
# Rooms a device may open outside the idle-heal pool in one window: a note the
# workspace restores into an editor on relaunch, a create-ack self-heal.
OTHER_ROOMS_PER_DEVICE = 4


def _chunks(items: list, n: int = _BATCH):
    for i in range(0, len(items), n):
        yield items[i : i + n]


async def create_notes(cdp, notes: dict[str, str]) -> None:
    """Create (or overwrite) markdown notes, creating parent folders."""
    for chunk in _chunks(list(notes.items())):
        await cdp.evaluate(
            f"""(async () => {{
                for (const [path, body] of {json.dumps(chunk)}) {{
                    const dir = path.slice(0, path.lastIndexOf('/'));
                    if (dir && !app.vault.getAbstractFileByPath(dir)) {{
                        try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
                    }}
                    const f = app.vault.getFileByPath(path);
                    if (f) await app.vault.modify(f, body); else await app.vault.create(path, body);
                }}
                return true;
            }})()""",
            await_promise=True,
        )


async def append_lines(cdp, edits: dict[str, str]) -> list[str]:
    """Append one line to each note via vault.process (atomic read-modify-write).

    Returns the paths that did not exist on this device, so callers can drop
    those markers from their expectation instead of guessing.
    """
    missing: list[str] = []
    for chunk in _chunks(list(edits.items())):
        missing += await cdp.evaluate(
            f"""(async () => {{
                const missing = [];
                for (const [path, line] of {json.dumps(chunk)}) {{
                    const f = app.vault.getFileByPath(path);
                    if (!f) {{ missing.push(path); continue; }}
                    await app.vault.process(f, s => s.endsWith('\\n') ? s + line + '\\n' : s + '\\n' + line + '\\n');
                }}
                return missing;
            }})()""",
            await_promise=True,
        )
    return missing


async def rename(cdp, old: str, new: str) -> bool:
    """Rename a file or folder; False if `old` is not on this device."""
    return await cdp.evaluate(
        f"""(async () => {{
            const f = app.vault.getAbstractFileByPath({json.dumps(old)});
            if (!f) return false;
            const dir = {json.dumps(new)}.slice(0, {json.dumps(new)}.lastIndexOf('/'));
            if (dir && !app.vault.getAbstractFileByPath(dir)) {{
                try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
            }}
            await app.vault.rename(f, {json.dumps(new)});
            return true;
        }})()""",
        await_promise=True,
    )


async def delete(cdp, paths: list[str]) -> list[str]:
    """Delete files or folders; returns the ones that were not on this device."""
    return await cdp.evaluate(
        f"""(async () => {{
            const missing = [];
            for (const p of {json.dumps(paths)}) {{
                const f = app.vault.getAbstractFileByPath(p);
                if (!f) {{ missing.push(p); continue; }}
                await app.vault.delete(f, true);
            }}
            return missing;
        }})()""",
        await_promise=True,
    )


async def create_binary(cdp, path: str, data: bytes) -> None:
    await cdp.evaluate(
        f"""(async () => {{
            const bytes = Uint8Array.from({json.dumps(list(data))});
            await app.vault.createBinary({json.dumps(path)}, bytes.buffer);
            return true;
        }})()""",
        await_promise=True,
    )


def api_append_many(api, edits: dict[str, str], workers: int = 8) -> None:
    """Server-side edits (POST /notes/append), several in flight at once.

    There is no batch write endpoint, so this is the bulk form: a small
    thread pool, every status checked. A device must not be able to tell
    these from another client's edits.
    """
    def one(item):
        path, line = item
        return path, api.append_note(path, line)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        bad = [(p, s) for p, s in pool.map(one, edits.items()) if s not in (200, 201)]
    assert not bad, f"{len(bad)} server appends failed, first: {bad[:5]}"


class RoomBudget:
    """Rooms the backend allocated in a window, against #644's per-device cap.

    The counter is node-wide (room_probe). Tests here run serially on a
    private vault, so the only other allocators are the session devices,
    idle on another vault. The bound counts handshake + edit starts, the two
    sources a device drives; create_batch and unknown are reported only.
    """

    def __init__(self, label: str) -> None:
        self.label = label
        arm_room_starts()
        self.start = read_room_starts()
        self.t0 = time.monotonic()

    def delta(self) -> RoomStarts:
        return read_room_starts() - self.start

    def bound(self, devices: int) -> int:
        minutes = (time.monotonic() - self.t0) / 60
        return devices * (HEAL_ROOM_BURST + math.ceil(HEAL_ROOMS_PER_MINUTE * minutes) + OTHER_ROOMS_PER_DEVICE)

    def check(self, devices: int) -> str | None:
        """None if within budget, else a failure message. Always logs the numbers."""
        d = self.delta()
        cap = self.bound(devices)
        minutes = (time.monotonic() - self.t0) / 60
        logger.warning(
            "GAUNTLET rooms %s: %s over %.1f min, client-driven %d, budget %d",
            self.label, d, minutes, d.handshake + d.edit, cap,
        )
        if d.handshake + d.edit > cap:
            return (
                f"{self.label}: {d.handshake + d.edit} client-driven room starts in {minutes:.1f} min "
                f"({d}), over the {cap} a {devices}-device heal budget allows"
            )
        return None
