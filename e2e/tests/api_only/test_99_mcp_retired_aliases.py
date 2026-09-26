"""Test 99: retired MCP tool names stay callable as aliases.

Task 3.1-3.2 kept `get_note`, `list_folders`, `patch_note`, `update_section`,
and `set_vault` callable after the 17-tool consolidation (`Engram.MCP.Tools`
`@retired` map) — clients that cached the old `tools/list` and our own skills
that call these by name must not break. Each alias:

  - answers 200 with `isError: false` (the old behavior, unchanged),
  - appends "(<old> is deprecated; use <new>.)" to the text content
    (`McpController.deprecation_note/2`),
  - returns the SAME `structuredContent` shape the old tool always returned.

One test per alias, each seeding its own note/folder so they don't collide
with the ~1000 other notes `api_sync`'s shared vault accumulates over a full
suite run.
"""

from __future__ import annotations

import uuid

import pytest


@pytest.fixture(scope="module")
def scoped(api_sync):
    """(vault-scoped ApiClient, vault_id) for api_sync's own vault.

    MCP resolves vault_id from the tool ARG, not X-Vault-ID (see test_32), but
    `with_vault` also pins the REST seeding calls below to the same vault the
    MCP calls target — api_sync's user may hold more than one vault in the
    api_only session (ensure_vaults registers a second one), and a bare REST
    write vs. an explicit-vault_id MCP read must not silently disagree.
    """
    vaults = api_sync.list_vaults()
    assert vaults, "api_sync user has no vaults"
    vault_id = vaults[0]["id"]
    return api_sync.with_vault(vault_id), vault_id


def _text(result: dict) -> str:
    return result["content"][0]["text"]


def test_get_note_alias_matches_get_notes(scoped):
    api, vault_id = scoped
    path = f"E2E/McpAlias99Get-{uuid.uuid4().hex[:8]}.md"
    content = "# Alias Get\nOriginal content for the get_note alias."
    api.create_note(path, content)
    api.wait_for_note(path)

    resp, status = api.mcp_call("get_note", {"source_path": path, "vault_id": vault_id})
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, f"get_note alias should succeed: {result}"
    assert "(get_note is deprecated; use get_notes.)" in _text(result)

    structured = result["structuredContent"]
    assert structured["path"] == path
    assert "Original content for the get_note alias." in structured["content"]


def test_list_folders_alias_matches_list_folder(scoped):
    api, vault_id = scoped
    folder = f"E2E/McpAlias99Folder-{uuid.uuid4().hex[:8]}"
    path = f"{folder}/Note.md"
    api.create_note(path, "# Folder Alias\nSeed note for the list_folders alias.")
    api.wait_for_note(path)

    resp, status = api.mcp_call("list_folders", {"vault_id": vault_id})
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, f"list_folders alias should succeed: {result}"
    assert "(list_folders is deprecated; use list_folder.)" in _text(result)

    structured = result["structuredContent"]
    match = next((f for f in structured["folders"] if f["folder"] == folder), None)
    assert match is not None, f"expected {folder!r} in list_folders output: {structured}"
    assert match["count"] == 1


def test_patch_note_alias_matches_edit_note(scoped):
    api, vault_id = scoped
    path = f"E2E/McpAlias99Patch-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Patch Alias\nOriginal sentence here.")
    api.wait_for_note(path)

    resp, status = api.mcp_call(
        "patch_note",
        {"path": path, "find": "Original", "replace": "Patched", "vault_id": vault_id},
    )
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, f"patch_note alias should succeed: {result}"
    assert "(patch_note is deprecated; use edit_note.)" in _text(result)
    assert result["structuredContent"] == {"path": path, "replacements": 1}

    updated = api.get_note(path)
    assert "Patched sentence here." in updated["content"]


def test_update_section_alias_matches_edit_note(scoped):
    api, vault_id = scoped
    path = f"E2E/McpAlias99Section-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Section Alias\n\n## Notes\nOld body.\n")
    api.wait_for_note(path)

    resp, status = api.mcp_call(
        "update_section",
        {"path": path, "heading": "Notes", "content": "New body.", "vault_id": vault_id},
    )
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, f"update_section alias should succeed: {result}"
    assert "(update_section is deprecated; use edit_note.)" in _text(result)
    assert result["structuredContent"] == {"path": path, "heading": "Notes"}

    updated = api.get_note(path)
    assert "New body." in updated["content"]


def test_set_vault_alias_matches_list_vaults(scoped):
    api, vault_id = scoped

    resp, status = api.mcp_call("set_vault", {"vault_id": vault_id})
    assert status == 200
    result = resp["result"]
    assert result["isError"] is False, f"set_vault alias should succeed: {result}"
    assert "(set_vault is deprecated; use list_vaults.)" in _text(result)
    assert result["structuredContent"]["vault"]["id"] == vault_id
