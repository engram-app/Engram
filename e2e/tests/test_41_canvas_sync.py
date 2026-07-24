"""Test 41: Canvas files (.canvas) sync between A and B.

Since #306 canvas syncs over the CRDT transport (structural Yjs — nodes/edges
Y.Maps), NOT the legacy REST pushNote path. The backend persists the canvas Yjs
state opaquely and keeps notes.content VESTIGIAL for canvas (it never
materializes canvas edits into notes.content — a new device rebuilds the board
from the Yjs deltas). So these tests assert CONVERGENCE on device B's disk, not
that the server's notes.content reflects the edit.
"""

import json

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_content, write_note


CANVAS_CONTENT = json.dumps({
    "nodes": [
        {"id": "node1", "type": "text", "text": "Hello canvas", "x": 0, "y": 0, "width": 200, "height": 100},
        {"id": "node2", "type": "text", "text": "Second node", "x": 300, "y": 0, "width": 200, "height": 100},
    ],
    "edges": [
        {"id": "edge1", "fromNode": "node1", "toNode": "node2"},
    ],
}, indent=2)


@pytest.mark.asyncio
async def test_canvas_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Canvas JSON file syncs A→B live with structure preserved."""
    path = "E2E/TestCanvas41.canvas"

    # A creates a canvas file
    write_note(vault_a, path, CANVAS_CONTENT)

    # Wait for push — canvas uses pushNote (text extension)
    await cdp_a.trigger_full_sync()

    # Server should have it
    note = api_sync.wait_for_note(path, timeout=10)
    assert note is not None, "Canvas should be on server"

    # B receives it live — no manual pull
    b_raw = wait_for_delivery(vault_b, path, api_sync, timeout=30)

    # Verify JSON structure is preserved
    b_data = json.loads(b_raw)
    assert len(b_data["nodes"]) == 2, "Canvas should have 2 nodes"
    assert len(b_data["edges"]) == 1, "Canvas should have 1 edge"
    assert b_data["nodes"][0]["text"] == "Hello canvas"


@pytest.mark.asyncio
async def test_canvas_modify_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Modifying a canvas on A propagates changes to B live."""
    path = "E2E/TestCanvasMod41.canvas"

    # Create base canvas, B receives it live
    write_note(vault_a, path, CANVAS_CONTENT)
    api_sync.wait_for_note(path, timeout=10)
    wait_for_delivery(vault_b, path, api_sync, timeout=30)

    # Modify canvas — add a node
    modified = json.loads(CANVAS_CONTENT)
    modified["nodes"].append({
        "id": "node3", "type": "text", "text": "New node",
        "x": 0, "y": 200, "width": 200, "height": 100,
    })
    write_note(vault_a, path, json.dumps(modified, indent=2))

    # NOTE: we do NOT assert the edit reaches the server's notes.content — since
    # #306 canvas content is vestigial on the server (the edit lives in the Yjs
    # state, not notes.content). Convergence is verified on B's disk below.
    #
    # B receives the modification live over the CRDT fan-out. B's file already
    # exists (from the base canvas above) so the delivery oracle's non-empty guard
    # can't detect this specific update; wait_for_content polls for the new node's
    # text instead — a pure vault-disk poll, no pull involved.
    b_raw = wait_for_content(vault_b, path, "New node", timeout=30)
    b_data = json.loads(b_raw)
    assert len(b_data["nodes"]) == 3, "Modified canvas should have 3 nodes"
