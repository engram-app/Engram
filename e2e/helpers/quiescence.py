"""Wait until sync has settled on both ends, instead of sleeping a fixed window.

Settled means, read twice in a row:
  - server: no checkpoint job pending for the vault (a cold note's CRDT updates
    fold in a debounced CheckpointNote, and the fold bumps change_seq), and
  - client: the catch-up cursor has reached the server's change_seq, and the
    device owes nothing outbound (debounced or running pushes, offline queue,
    CRDT op queue, in-flight flushes and creates).

A fixed sleep can pass while that work is still pending; this cannot. The
deadline is a true-breakage bound, not an expected wait.

`pending_crdt_updates` is deliberately NOT a settle condition: it counts the
whole session vault, and a note another test left open in an editor holds its
updates in a live room until that room checkpoints. It is reported on timeout.
"""

from __future__ import annotations

import asyncio
import json
import time

from helpers.cdp import PLUGIN_PATH

PROBE = f"JSON.stringify({PLUGIN_PATH}.syncQuiescence())"
OWED = ("pushing", "pendingPushes", "queued", "flushing", "creating", "crdtOps")


def _settled(server: dict, client: dict, caught_up: bool) -> bool:
    return (
        server["pending_checkpoints"] == 0
        and (not caught_up or client["catchupSeq"] >= server["change_seq"])
        and not client["pulling"]
        and all(client[k] == 0 for k in OWED)
    )


async def await_quiescent(
    cdp, api, *, deadline_s: float = 60.0, kick: bool = True, caught_up: bool = True
) -> None:
    """Return once `cdp`'s device and the server are both settled.

    `kick` runs a fullSync per poll so the catch-up cursor can advance past the
    server's latest seq (catch-up runs on sync triggers, not continuously). A
    test that must not route work through fullSync passes `kick=False`, and
    then `caught_up=False` too, since without a kick the cursor only moves on
    live delivery; it still waits for every outbound send and server fold.
    """
    end = time.monotonic() + deadline_s
    in_a_row = 0
    server = client = None
    while time.monotonic() < end:
        if kick:
            await cdp.trigger_full_sync()
        server = api.get_quiescence()
        client = json.loads(await cdp.evaluate(PROBE))
        in_a_row = in_a_row + 1 if _settled(server, client, caught_up) else 0
        if in_a_row >= 2:
            return
        await asyncio.sleep(0.5)
    raise AssertionError(
        f"sync did not settle within {deadline_s}s: server={server} client={client}"
    )


async def await_indexed_change(cdp, rel: str, before_mtime: float, deadline_s: float = 10.0) -> None:
    """Return once Obsidian's cached stat for `rel` has moved past `before_mtime`.

    A write made straight to disk reaches the plugin only after Obsidian's file
    watcher fires; settling before that would see nothing owed and pass early.
    """
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        mtime = await cdp.evaluate(f"app.vault.getFileByPath({json.dumps(rel)})?.stat.mtime ?? 0")
        if mtime and mtime > before_mtime:
            return
        await asyncio.sleep(0.1)
    raise AssertionError(f"Obsidian never registered the write to {rel}")


async def indexed_mtime(cdp, rel: str) -> float:
    return await cdp.evaluate(f"app.vault.getFileByPath({json.dumps(rel)})?.stat.mtime ?? 0") or 0
