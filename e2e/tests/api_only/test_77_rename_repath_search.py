"""Test 77: after a folder rename, search finds the note under its NEW folder
and no longer under the OLD one (#746, end-to-end).

R3a: a rename makes ZERO Qdrant writes. A point's payload is the note's
identity (`u`, `v`, `n`); Postgres resolves the folder filter to note ids, so
the rename transaction alone moves the note. This test keeps proving the
user-facing seam against a real Qdrant:

  1. A folder-scoped `/api/search` finds the note under its NEW folder.
  2. The same search under the OLD folder returns nothing.

API-only (no Obsidian, no Clerk gate). Mirrors test_67's index-then-search
shape; step 1 still polls (search runs on the request path, no job to wait
for, but the poll is harmless).
"""

from __future__ import annotations

import logging
import os
import time

from helpers.crypto_probe import (
    latest_note_path_hmac,
    wait_for_chunks_committed,
    wait_for_qdrant_indexed,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


class TestRenameRepathSearch:
    """A folder rename must move the note's Qdrant points to the new
    folder_hmac without re-embedding, so folder-filtered search follows it."""

    def test_folder_rename_repaths_points_in_qdrant(self, api_sync):
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
        wait_for_qdrant_indexed(vault_id, old_path_hmac, old_path)
        # Search rehydrates hits from chunk rows, which commit AFTER the
        # Qdrant upsert; a hit with no row yet is dropped.
        wait_for_chunks_committed(vault_id, old_path_hmac, old_path, timeout=90)

        # 1a. Baseline: folder-scoped search finds it under the OLD folder.
        before = self._search(client, query, folder=src_folder, limit=10)
        assert {r.get("path") for r in before} == {old_path}, (
            f"baseline: search in {src_folder!r} should find {old_path!r}, "
            f"got {[r.get('path') for r in before]}"
        )

        # 2. Rename the folder. This repoints the note row (new path_hmac /
        #    folder_hmac): no re-embed, no Qdrant write.
        status = client.rename_folder(src_folder, dst_folder)
        assert status == 200, f"rename_folder returned {status}"

        # 3. Folder-scoped search under the NEW folder returns the note at its
        #    new path: Postgres resolves the folder, and the points were kept.
        found = self._poll_search(client, query, folder=dst_folder, want=new_path, timeout=90)
        assert found, (
            f"after rename, search in {dst_folder!r} never returned {new_path!r} "
            f"within 90s"
        )

        # 4. The OLD folder filter must now return nothing (no ghost match).
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
        # Goes through ApiClient.search so this shares the ONE search timeout
        # budget (SEARCH_TIMEOUT). A hand-rolled session.post here silently opts
        # out of it and reintroduces the load-sensitive ReadTimeout class.
        return client.search(query, folder=folder, limit=limit)

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
