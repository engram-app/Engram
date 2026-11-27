"""Test 109: a create refused because the name is taken is final, not retried.

A device that still holds a deleted note's id can send `crdt_create` for that
id at a path another live note now holds (a stale device, a restored backup).
The server cannot resurrect it there: the path is taken. It used to answer
the generic `create_failed`, which the plugin must treat as retryable, so it:

* re-sent the create up to 8 times over ~5 minutes, then again on every sync;
* closed its vault-wide create backoff, pausing EVERY create in the vault for
  30 s, doubling to 10 min.

The server now answers `id_conflict` for a taken path, the reason every plugin
already treats as final. This test stages that exact server state through the
API and puts the op in the REAL plugin's durable CRDT op queue, so the
plugin's own dispatch and the server's reply are both under test.

Oracles, scoped to a per-test uuid folder:
1. the plugin sends the create ONCE over a window long enough for several
   retries (base backoff 500 ms, doubling), and the op leaves the queue;
2. the vault-wide create backoff never closes;
3. a fresh note written afterwards still reaches the server.
"""

import asyncio
import uuid

import pytest

from helpers.cdp import ENGINE_PATH, PLUGIN_PATH
from helpers.vault import write_note

# Long enough for the old behaviour to retry several times (500 ms base
# backoff, doubling, on a 5 s queue tick) and short enough for the session.
WINDOW_S = 40


@pytest.mark.asyncio
async def test_name_taken_create_is_not_retried(obsidian_b, cdp_b, api_sync):
    root = f"E2E/NameTaken109-{uuid.uuid4().hex[:12]}"
    gone_path, taken_path, later_path = (
        f"{root}/was.md",
        f"{root}/taken.md",
        f"{root}/later.md",
    )

    # Server state: X deleted (a tombstone), Y live at the path X will ask for.
    api_sync.create_note(gone_path, "# was")
    gone_id = api_sync.wait_for_note_id(gone_path)
    assert api_sync.delete_note(gone_path) in (200, 204)
    api_sync.create_note(taken_path, "# taken")
    holder_id = api_sync.wait_for_note_id(taken_path)

    # Count every crdt_create the plugin sends for X on the live channel.
    await cdp_b.evaluate(
        f"""(() => {{
            const ch = {PLUGIN_PATH}.noteStream;
            if (!ch) throw new Error('no noteStream');
            window.__e2e109 = {{ ch, orig: ch.crdtCreate, calls: 0 }};
            ch.crdtCreate = function (docId, ...rest) {{
                if (docId === '{gone_id}') window.__e2e109.calls++;
                return window.__e2e109.orig.call(this, docId, ...rest);
            }};
        }})()"""
    )
    try:
        await cdp_b.evaluate(
            f"""(() => {{
                const p = {PLUGIN_PATH};
                p.crdtOpQueue.enqueue({{
                    id: 'e2e109-' + Date.now(), kind: 'create', docId: '{gone_id}',
                    payload: {{ path: '{taken_path}' }}, enqueuedAt: Date.now(),
                    attempts: 0, vaultId: p.settings.vaultId ?? null,
                }});
                return p.crdtOpQueue.tick();
            }})()""",
            await_promise=True,
        )

        await asyncio.sleep(WINDOW_S)
        calls = await cdp_b.evaluate("window.__e2e109.calls")
        ops = [o for o in await cdp_b.get_crdt_queue_ops() if o.get("docId") == gone_id]
        gate_closed = await cdp_b.evaluate(f"!!{ENGINE_PATH}.notesCapGate?.isClosed()")
    finally:
        await cdp_b.evaluate(
            "(() => { const s = window.__e2e109; if (s) s.ch.crdtCreate = s.orig;"
            " delete window.__e2e109; })()"
        )

    assert calls == 1, (
        f"a taken-name create must be sent once, not retried; sent {calls}x"
    )
    assert not ops, f"a taken-name create must leave the queue; still queued: {ops}"
    assert not gate_closed, (
        "a taken-name create must not pause every create in the vault"
    )

    # The holder is untouched, and creates elsewhere are not blocked.
    assert api_sync.wait_for_note_id(taken_path) == holder_id
    write_note(obsidian_b.vault_path, later_path, "# later")
    api_sync.wait_for_note(later_path, timeout=30)

    for path in (taken_path, later_path):
        api_sync.delete_note(path)
