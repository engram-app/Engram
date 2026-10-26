"""Bulk vault operations and the room-start budget for the release-gauntlet tests.

Every device-side write goes through Obsidian's vault API in ONE CDP call per
batch (not one evaluate per file), so a 1,000-note setup is a handful of round
trips and the plugin sees the same `create`/`modify`/`rename`/`delete` events
a user's edits fire.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import time
from concurrent.futures import ThreadPoolExecutor

from helpers.cdp import PLUGIN_PATH
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


async def replace_text(cdp, path: str, old: str, new: str) -> bool:
    """Replace the first `old` with `new` in one note via vault.process.
    False if the note or the text is not on this device."""
    return await cdp.evaluate(
        f"""(async () => {{
            const f = app.vault.getFileByPath({json.dumps(path)});
            if (!f) return false;
            let hit = false;
            await app.vault.process(f, s => {{
                if (!s.includes({json.dumps(old)})) return s;
                hit = true;
                return s.replace({json.dumps(old)}, {json.dumps(new)});
            }});
            return hit;
        }})()""",
        await_promise=True,
    )


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


# -- crdt_create interception -------------------------------------------------
#
# Fault injection on ONE channel request type, the way a lossy link or a slow
# server would shape it, without touching the rest of the socket. Each
# crdt_create the device makes takes the next action from `plan` (then
# `rest`). Actions:
#   pass            send normally
#   drop            never send; reject after the request's own timeout (a lost push)
#   delay:<ms>      send after <ms>
#   hold            send once window.__e2eRelease is set
#   noreply         send, but never resolve (the server stores it, the ack is lost)
#   lateack:<ms>    send, resolve the reply <ms> late
#   holdack         send, resolve the reply only once window.__e2eRelease is set
# Every call is recorded in window.__e2eCreates ({path, action, at}).
# set_create_rest() switches the action for every later call.

_HOOK = """(() => {
    const ch = %(plugin)s.noteStream;
    const orig = ch.__e2eOrigSendRequest || ch.sendRequest.bind(ch);
    ch.__e2eOrigSendRequest = orig;
    const plan = %(plan)s, rest = %(rest)s;
    window.__e2eCreates = []; window.__e2eRelease = false; window.__e2eRestOverride = null;
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    ch.sendRequest = (event, payload, timeoutMs = 10000) => {
        if (event !== 'crdt_create') return orig(event, payload, timeoutMs);
        const i = window.__e2eCreates.length;
        const action = i < plan.length ? plan[i] : (window.__e2eRestOverride || rest);
        window.__e2eCreates.push({path: payload.path, docId: payload.doc_id, action, at: Date.now()});
        if (window.__e2eBufferOnCreate) window.__e2eBuffering = true;
        const [kind, arg] = action.split(':');
        const ms = Number(arg || 0);
        if (kind === 'drop') return sleep(timeoutMs).then(() => { throw new Error('sendRequest timeout: crdt_create'); });
        if (kind === 'delay') return sleep(ms).then(() => orig(event, payload, timeoutMs));
        if (kind === 'hold') return (async () => { while (!window.__e2eRelease) await sleep(100); return orig(event, payload, timeoutMs); })();
        if (kind === 'noreply') { orig(event, payload, timeoutMs).catch(() => {}); return new Promise(() => {}); }
        if (kind === 'holdack') return orig(event, payload, timeoutMs).then(async r => { window.__e2eAckHeld = true; while (!window.__e2eRelease) await sleep(100); return r; });
        if (kind === 'lateack') return orig(event, payload, timeoutMs).then(async r => { await sleep(ms); return r; });
        return orig(event, payload, timeoutMs);
    };
    return 'armed';
})()"""

_UNHOOK = """(() => {
    const ch = %(plugin)s.noteStream;
    if (ch.__e2eOrigSendRequest) { ch.sendRequest = ch.__e2eOrigSendRequest; delete ch.__e2eOrigSendRequest; }
    window.__e2eRelease = true;
    return JSON.stringify(window.__e2eCreates || []);
})()"""


async def hook_creates(cdp, plan: list[str], rest: str = "pass", timeout: float = 60) -> None:
    # After a relaunch the channel object is built a moment after the plugin
    # reports ready; hooking a null noteStream would throw.
    end = time.monotonic() + timeout
    while not await cdp.evaluate(f"!!{PLUGIN_PATH}.noteStream"):
        assert time.monotonic() < end, f"no noteStream after {timeout}s"
        await asyncio.sleep(0.2)
    out = await cdp.evaluate(_HOOK % {"plugin": PLUGIN_PATH, "plan": json.dumps(plan), "rest": json.dumps(rest)})
    assert out == "armed", out


async def creates_seen(cdp) -> list[dict]:
    return json.loads(await cdp.evaluate("JSON.stringify(window.__e2eCreates || [])"))


async def set_create_rest(cdp, action: str) -> None:
    await cdp.evaluate(f"window.__e2eRestOverride = {json.dumps(action)}")


async def release_creates(cdp) -> None:
    await cdp.evaluate("window.__e2eRelease = true")


async def unhook_creates(cdp) -> list[dict]:
    return json.loads(await cdp.evaluate(_UNHOOK % {"plugin": PLUGIN_PATH}))


# -- inbound frame buffering ----------------------------------------------------
#
# Hold every frame the server sends this device, then deliver them in arrival
# order back to back. With `on_create=True` buffering starts the moment the
# next crdt_create goes out (needs hook_creates armed), so its reply and any
# broadcast that follows land together, reply first.

_BUFFER = """(() => {
    const ch = %(plugin)s.noteStream;
    if (!ch.__e2eOrigHandle) {
        const orig = ch.handleMessage.bind(ch);
        ch.__e2eOrigHandle = orig;
        window.__e2eInbound = [];
        ch.handleMessage = raw => window.__e2eBuffering ? window.__e2eInbound.push(raw) : orig(raw);
    }
    window.__e2eBufferOnCreate = %(on_create)s;
    window.__e2eBuffering = !%(on_create)s;
    return 'buffering';
})()"""

_FLUSH = """(() => {
    const ch = %(plugin)s.noteStream;
    window.__e2eBuffering = false; window.__e2eBufferOnCreate = false;
    const held = window.__e2eInbound || [];
    window.__e2eInbound = [];
    for (const raw of held) ch.__e2eOrigHandle(raw);
    if (ch.__e2eOrigHandle) { ch.handleMessage = ch.__e2eOrigHandle; delete ch.__e2eOrigHandle; }
    return held.length;
})()"""


async def buffer_inbound(cdp, *, on_create: bool = False) -> None:
    out = await cdp.evaluate(_BUFFER % {"plugin": PLUGIN_PATH, "on_create": json.dumps(on_create)})
    assert out == "buffering", out


async def inbound_held(cdp) -> int:
    return await cdp.evaluate("(window.__e2eInbound || []).length")


async def flush_inbound(cdp) -> int:
    """Deliver the held frames in arrival order and stop buffering."""
    return await cdp.evaluate(_FLUSH % {"plugin": PLUGIN_PATH})
