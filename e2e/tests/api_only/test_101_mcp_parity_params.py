"""Test 101: MCP parity params (#1793) against the real stack.

insert_section writes through the normal save path and lands where a reader
expects; include_links reads the note_links graph the indexing job builds, so
it polls until extraction has run. outline and the blank-query recent listing
are both cheap DB round-trips (no embedding), so they need no poll.

similar_to is deliberately NOT covered here: it depends on the note already
holding a stored dense vector from the async embed pipeline, and this suite
has no reliable signal for "embedding finished" short of polling search
itself — not worth the flake budget for a param already covered by the
Elixir unit suite (test/engram/mcp/handlers_similar_test.exs).
"""

from __future__ import annotations

import time
import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT


@pytest.fixture(scope="module")
def scoped(api_sync):
    vaults = api_sync.list_vaults()
    assert vaults, "api_sync user has no vaults"
    vault_id = vaults[0]["id"]
    return api_sync.with_vault(vault_id), vault_id


def test_insert_section_end_and_start(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity101Insert-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Insert\n\n## Todo\n\n- a\n\n### Sub\n\n- s\n\n## Done\n\n- x\n")
    api.wait_for_note(path)

    for position, text in (("end", "- last"), ("start", "- first")):
        resp, status = api.mcp_call(
            "edit_note",
            {"path": path, "mode": "insert_section", "heading": "Todo",
             "content": text, "position": position, "vault_id": vault_id},
        )
        assert status == 200
        result = resp["result"]
        assert result["isError"] is False, result
        assert result["structuredContent"]["mode"] == "insert_section"

    content = api.get_note(path)["content"]
    assert "## Todo\n- first\n" in content
    assert "### Sub\n\n- s\n- last\n\n## Done" in content


def test_insert_section_missing_heading_writes_nothing(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity101Missing-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Missing\n\n## Todo\n\n- a\n")
    api.wait_for_note(path)
    before = api.get_note(path)["content"]

    resp, status = api.mcp_call(
        "edit_note",
        {"path": path, "mode": "insert_section", "heading": "Nope",
         "content": "- y", "vault_id": vault_id},
    )
    assert status == 200
    assert resp["result"]["isError"] is True
    assert api.get_note(path)["content"] == before


def test_get_notes_include_links(scoped):
    api, vault_id = scoped
    tag = uuid.uuid4().hex[:8]
    target = f"E2E/McpParity101Target-{tag}.md"
    source = f"E2E/McpParity101Source-{tag}.md"
    api.create_note(target, f"# Target\n\nsee [[Ghost-{tag}]]")
    api.create_note(source, f"# Source\n\nsee [[McpParity101Target-{tag}]]")
    api.wait_for_note(target)
    api.wait_for_note(source)

    # Link extraction runs in the indexing job, so poll.
    deadline = time.monotonic() + DELIVERY_TIMEOUT
    note = None
    missing = None
    while time.monotonic() < deadline:
        resp, status = api.mcp_call(
            "get_notes",
            {"paths": [target, f"E2E/Nope-{tag}.md"], "include_links": True, "vault_id": vault_id},
        )
        assert status == 200
        result = resp["result"]
        assert result["isError"] is False, result
        note, missing = result["structuredContent"]["notes"]
        if source in note.get("backlinks", []) and note.get("unresolved"):
            break
        time.sleep(2)

    assert source in note["backlinks"], note
    assert note["unresolved"] == [f"Ghost-{tag}"], note
    assert missing == {"path": f"E2E/Nope-{tag}.md", "found": False}


def test_get_notes_outline(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity101Outline-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# T\n\n## Todo\n\n- a\n\n### Sub\n\n- s\n\n## Done\n\n- x\n")
    api.wait_for_note(path)

    resp, status = api.mcp_call(
        "get_notes", {"paths": [path], "outline": True, "vault_id": vault_id}
    )
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, result
    note = result["structuredContent"]["notes"][0]
    assert note["outline"] == [
        {"level": 1, "heading": "T"},
        {"level": 2, "heading": "Todo"},
        {"level": 3, "heading": "Sub"},
        {"level": 2, "heading": "Done"},
    ]
    assert "content" not in note


def test_search_notes_blank_query_lists_recent(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity101Recent-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Recent\n\nfresh note for the recent listing")
    api.wait_for_note(path)

    resp, status = api.mcp_call(
        "search_notes", {"query": "", "limit": 20, "vault_id": vault_id}
    )
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, result
    hits = result["structuredContent"]["results"]
    match = next((h for h in hits if h["source_path"] == path), None)
    assert match is not None, hits
    assert match["score"] == 0
