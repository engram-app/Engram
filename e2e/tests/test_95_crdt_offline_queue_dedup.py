"""Test 95: a create superseded by a delete while offline must not resurrect.

The `#1315` dedup box, aimed at the part of it that can actually fail.

`CrdtOpQueue.entries` is a `Map<docId, Entry>` (`crdt-op-queue.ts`), so "one
pending op per docId" is a STRUCTURAL property of the data structure — an
assertion counting entries per docId can never fail, whatever the plugin does.
Likewise, content edits never enter this queue at all: `crdtEnqueue` is typed
`kind: "create" | "delete"`, and revisions converge through the Yjs doc's own
offline buffer. Asserting "the latest revision won" would therefore be testing
Yjs buffering wearing an op-queue label.

What IS real logic, and what `main.ts` calls out explicitly (the #416 review's
supersede exception), is WHICH op survives when two land on the same docId
offline: a create followed by a delete must collapse so the note does not come
back when the queue flushes. Getting that wrong resurrects a note the user
deleted, which is the failure worth a test.
"""

import asyncio
import json
import uuid

import pytest

from helpers.vault import delete_note, write_note


@pytest.mark.asyncio
async def test_offline_create_then_delete_does_not_resurrect(vault_a, cdp_a, api_sync):
    """Create and delete the same note while offline; it must not exist after the flush."""
    path = "E2E/CrdtQueueDedup95.md"

    write_note(vault_a, "E2E/CrdtQueueDedup95base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueueDedup95base.md")

    await cdp_a.disconnect_stream()
    assert not await cdp_a.check_stream_connected(), (
        "disconnect_stream() must actually drop the channel"
    )

    try:
        write_note(vault_a, path, "# Dedup 95\ncreated while offline")

        # Wait for the create to actually be held before superseding it, or the
        # test can race past the state it means to set up and pass vacuously.
        deadline = asyncio.get_event_loop().time() + 20
        while asyncio.get_event_loop().time() < deadline:
            ops = await cdp_a.get_crdt_queue_ops()
            if any(o.get("path") == path for o in ops):
                break
            await asyncio.sleep(0.5)
        else:
            pytest.fail(f"precondition: the offline create was never held, queue={ops}")

        delete_note(vault_a, path)
        # Barrier: Obsidian's index has seen the delete, so the plugin's delete
        # handler ran while the channel was still down.
        deadline = asyncio.get_event_loop().time() + 20
        while await cdp_a.evaluate(
            f"app.vault.getAbstractFileByPath({json.dumps(path)}) !== null"
        ):
            if asyncio.get_event_loop().time() >= deadline:
                pytest.fail(f"precondition: Obsidian never saw the delete of {path}")
            await asyncio.sleep(0.2)
    finally:
        await cdp_a.reconnect_stream()

    await cdp_a.wait_for_crdt_queue_drain(timeout=45)

    # The note must not exist on the server. A queue that flushed the create
    # after the delete had superseded it would recreate a note the user removed.
    # The assertion is a NEGATIVE, so checking it the instant the queue empties
    # could pass before a late create lands. Barrier: push a sentinel over the
    # same CRDT channel and wait for it on the server; the channel processes
    # frames in order, so any create flushed before it has landed too.
    sentinel = f"E2E/CrdtQueueDedup95-sentinel-{uuid.uuid4().hex[:12]}.md"
    try:
        await cdp_a.push_file_now(sentinel, "# sentinel")
        api_sync.wait_for_note(sentinel)
    finally:
        api_sync.delete_note(sentinel)
        delete_note(vault_a, sentinel)
    assert api_sync.get_note(path) is None, (
        "a create superseded by an offline delete resurrected the note on flush"
    )
