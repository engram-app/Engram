"""Test 77: folder rename repaths Qdrant points — search finds the note under
its NEW folder and no longer under the OLD one (#746, end-to-end).

Renaming a folder updates each note's path_hmac/folder_hmac on the row inside
the rename transaction, then the `RepathNoteIndex` Oban worker PATCHes the
existing Qdrant points' path_hmac/folder_hmac in place — no re-embed. The unit
tests prove the wire contract and that the embedder is never called; this test
proves the repath actually lands in a real Qdrant by exercising the user-facing
seam:

  1. A folder-scoped `/api/search` (folder -> folder_hmac -> Qdrant filter)
     finds the note under its NEW folder after the rename.
  2. The same search under the OLD folder returns nothing — the points no
     longer carry the old folder_hmac.

The "zero Voyage calls" half is covered by `RepathNoteIndexTest`
(no-Mox-expectation); e2e has no way to count embedder calls.

API-only (no Obsidian, no Clerk gate). Mirrors test_67's index-then-search
shape; the repath runs asynchronously (Oban, ~3s debounce), so step 1 polls.
"""

from __future__ import annotations

import logging
import os
import time

from helpers.crypto_probe import latest_note_path_hmac, wait_for_qdrant_indexed

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


class TestRenameRepathSearch:
    """A folder rename must move the note's Qdrant points to the new
    folder_hmac without re-embedding, so folder-filtered search follows it."""

    def test_folder_rename_repaths_points_in_qdrant(self, api_sync, qdrant_collection):
        vaults = api_sync.list_vaults()
        assert vaults, "api_sync should have a registered vault"
        vault_id = vaults[0]["id"]
        client = api_sync.with_vault(vault_id)

        ts = int(time.time())
        src_folder = f"repath-src-{ts}"
        dst_folder = f"repath-dst-{ts}"
        filename = f"note-{ts}.md"
        old_path = f"{src_folder}/{filename}"
        new_path = f"{dst_folder}/{filename}"
        # Distinctive token so the query matches exactly this note.
        query = f"zzrepathfingerprint{ts}"

        # 1. Seed one note in the source folder and let the embed worker land
        #    it in Qdrant under the old path_hmac.
        resp = client.session.post(
            f"{API_URL}/notes",
            json={
                "path": old_path,
                "content": f"# Repath note\n\n{query} body content here.\n",
                "mtime": time.time(),
            },
            timeout=10,
        )
        assert resp.ok, f"upsert {old_path} failed: {resp.status_code} {resp.text[:300]}"

        old_path_hmac = latest_note_path_hmac(vault_id)
        wait_for_qdrant_indexed(vault_id, old_path_hmac, old_path, timeout=90, collection=qdrant_collection)

        # 1a. Baseline: folder-scoped search finds it under the OLD folder.
        before = self._search(client, query, folder=src_folder, limit=10)
        assert {r.get("path") for r in before} == {old_path}, (
            f"baseline: search in {src_folder!r} should find {old_path!r}, "
            f"got {[r.get('path') for r in before]}"
        )

        # 2. Rename the folder. This repoints the note row (new path_hmac /
        #    folder_hmac) and enqueues RepathNoteIndex — NOT a re-embed.
        status = client.rename_folder(src_folder, dst_folder)
        assert status == 200, f"rename_folder returned {status}"

        # 3. Poll until the repath lands: folder-scoped search under the NEW
        #    folder returns the note at its new path. This only succeeds if the
        #    Qdrant points now carry the new folder_hmac AND path_hmac — i.e.
        #    the points were PATCHed in place, not deleted.
        found = self._poll_search(client, query, folder=dst_folder, want=new_path, timeout=90)
        assert found, (
            f"after rename, search in {dst_folder!r} never returned {new_path!r} "
            f"within 90s — repath did not land in Qdrant"
        )

        # 4. The OLD folder filter must now return nothing — the points no
        #    longer carry the old folder_hmac. (Guards a repath that ADDED the
        #    new hmac without overwriting the old, leaving ghost matches.)
        after_old = self._search(client, query, folder=src_folder, limit=10)
        assert after_old == [], (
            f"after rename, search in old folder {src_folder!r} should be empty, "
            f"got {[r.get('path') for r in after_old]}"
        )

    @staticmethod
    def _search(
        client,
        query: str,
        *,
        folder: str | None = None,
        limit: int = 10,
    ) -> list[dict]:
        body: dict = {"query": query, "limit": limit}
        if folder is not None:
            body["folder"] = folder

        resp = client.session.post(f"{API_URL}/search", json=body, timeout=30)
        assert resp.status_code == 200, (
            f"/api/search failed: {resp.status_code} {resp.text[:300]}"
        )
        return resp.json().get("results", [])

    def _poll_search(
        self,
        client,
        query: str,
        *,
        folder: str,
        want: str,
        timeout: float = 90.0,
    ) -> bool:
        """Poll folder-scoped search until `want` appears (repath is async)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            results = self._search(client, query, folder=folder, limit=10)
            if want in {r.get("path") for r in results}:
                return True
            time.sleep(2)
        return False
