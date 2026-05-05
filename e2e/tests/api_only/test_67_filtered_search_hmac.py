"""Test 67: /api/search folder + tag filtering against an encrypted vault.

Phase B.2.3 read switch: when an encrypted vault posts `?folder=` or `?tags=`
on /api/search, the backend must translate the plaintext params into
HMAC fingerprints (folder_hmac / tags_hmac) and forward them to Qdrant.
Qdrant points carry only HMACs — never the plaintext folder or tag — yet
the API caller still gets human-readable results back.

This test proves end-to-end that:
  1. Plaintext `folder` filter narrows the result set (papers/quantum).
  2. Plaintext `tags` filter narrows the result set.
  3. Combined filters compose (must-match-all).
  4. Unfiltered search still returns multiple matches.

API-only (no Obsidian, no Clerk gate). Reuses the encrypted vault pattern
from test_62: toggles encryption via the real endpoint, writes notes via
HTTP, lets the embed worker index them, then exercises /api/search.
"""

from __future__ import annotations

import logging
import os
import time

import pytest

from helpers.crypto_probe import (
    backdate_decrypt_requested,
    backdate_last_toggle,
    wait_for_encryption_status,
    wait_for_qdrant_indexed,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


def _frontmatter_note(title: str, tags: list[str], body: str) -> str:
    tag_list = ", ".join(tags)
    return (
        f"---\n"
        f"tags: [{tag_list}]\n"
        f"---\n"
        f"# {title}\n\n"
        f"{body}\n"
    )


@pytest.fixture
def reset_vault_encryption(api_sync):
    """Roll the shared vault back to 'none' status — same SQL time-travel
    pattern as test_62. Idempotent if the vault is already 'none'."""
    yield
    vaults = api_sync.list_vaults()
    if not vaults:
        return
    vault_id = vaults[0]["id"]
    resp = api_sync.session.get(
        f"{API_URL}/vaults/{vault_id}/encryption_progress", timeout=5
    )
    if not resp.ok:
        return
    status = resp.json().get("status")
    if status in ("encrypted", "encrypting"):
        if status == "encrypting":
            wait_for_encryption_status(api_sync, vault_id, "encrypted", timeout=60)
        backdate_last_toggle(vault_id, days=8)
        api_sync.session.post(f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10)
        backdate_decrypt_requested(vault_id, hours=25)
        wait_for_encryption_status(api_sync, vault_id, "none", timeout=60)
        backdate_last_toggle(vault_id, days=8)


class TestFilteredSearchOnEncryptedVault:
    """Folder + tag filters on /api/search against an encrypted vault must
    translate to HMAC filters in Qdrant and still narrow the result set."""

    def test_folder_and_tag_filters_compose(self, api_sync, reset_vault_encryption):
        vaults = api_sync.list_vaults()
        assert vaults, "api_sync should have a registered vault"
        vault_id = vaults[0]["id"]
        client = api_sync.with_vault(vault_id)

        # 1. Toggle vault to encrypted (empty vault, near-instant)
        resp = client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202, (
            f"encrypt failed: {resp.status_code} {resp.text[:300]}"
        )
        wait_for_encryption_status(client, vault_id, "encrypted", timeout=30)

        # 2. Write three notes with distinct folders + tags. The shared
        #    keyword "fingerprint" lets one query match all three so we
        #    can verify the filter (not the embedding) does the narrowing.
        ts = int(time.time())
        target_path = f"papers/research/quantum-{ts}.md"
        target_tag = f"physics-{ts}"

        note_specs = [
            (target_path, ["research", target_tag], "Quantum entanglement fingerprint study"),
            (f"papers/notes/coffee-{ts}.md", ["lifestyle"], "Coffee brewing fingerprint"),
            (f"journal/today-{ts}.md", ["personal"], "Daily journal fingerprint entry"),
        ]

        for path, tags, body in note_specs:
            resp = client.session.post(
                f"{API_URL}/notes",
                json={
                    "path": path,
                    "content": _frontmatter_note("Note", tags, body),
                    "mtime": time.time(),
                },
                timeout=10,
            )
            assert resp.ok, (
                f"upsert {path} failed: {resp.status_code} {resp.text[:300]}"
            )

        # 3. Wait for the embed worker to land all three in Qdrant
        for path, _, _ in note_specs:
            wait_for_qdrant_indexed(vault_id, path, timeout=90)

        # 3a. Sanity — confirm frontmatter parsing landed `target_tag` on the
        #     target note. Without this guard, a future regression in
        #     `Helpers.extract_tags/1` could silently produce empty tags and
        #     the tag filter test below would still narrow to one note (for
        #     the wrong reason: matching no-tag rows vs. matching by HMAC).
        target_note = client.get_note(target_path)
        assert target_note is not None, (
            f"Target note {target_path} should be retrievable for sanity check"
        )
        assert target_tag in (target_note.get("tags") or []), (
            f"Frontmatter parser did not extract {target_tag!r}. "
            f"Got tags={target_note.get('tags')!r} — tag filter test below "
            f"would pass for the wrong reason without this guard."
        )

        # 4. Unfiltered search must hit every seeded note. Assert the count
        #    so a regression that drops two of three results (and happens to
        #    keep target_path) doesn't silently pass.
        unfiltered = self._search(client, "fingerprint", limit=20)
        unfiltered_paths = {r.get("path") for r in unfiltered}
        seeded_paths = {p for p, _, _ in note_specs}
        assert seeded_paths <= unfiltered_paths, (
            f"Unfiltered search missed seeded notes. "
            f"Missing: {seeded_paths - unfiltered_paths}. Got: {unfiltered_paths}"
        )

        # 5. Folder filter must narrow to one note
        by_folder = self._search(
            client, "fingerprint", folder="papers/research", limit=20
        )
        by_folder_paths = {r.get("path") for r in by_folder}
        assert by_folder_paths == {target_path}, (
            f"folder filter should match exactly {{{target_path}}}, "
            f"got {by_folder_paths}"
        )

        # 6. Tag filter must narrow to one note
        by_tag = self._search(client, "fingerprint", tags=[target_tag], limit=20)
        by_tag_paths = {r.get("path") for r in by_tag}
        assert by_tag_paths == {target_path}, (
            f"tag filter should match exactly {{{target_path}}}, got {by_tag_paths}"
        )

        # 7. Combined filters compose (must-match-all)
        combined = self._search(
            client,
            "fingerprint",
            folder="papers/research",
            tags=[target_tag],
            limit=20,
        )
        combined_paths = {r.get("path") for r in combined}
        assert combined_paths == {target_path}, (
            f"combined filter should match {{{target_path}}}, got {combined_paths}"
        )

        # 8. Mismatched filters return zero (HMAC for nonexistent tag must
        #    not collide with anything indexed)
        empty = self._search(
            client, "fingerprint", tags=[f"nonexistent-{ts}"], limit=20
        )
        assert empty == [], (
            f"unknown tag should return empty results, got {empty}"
        )

    @staticmethod
    def _search(
        client,
        query: str,
        *,
        folder: str | None = None,
        tags: list[str] | None = None,
        limit: int = 5,
    ) -> list[dict]:
        body: dict = {"query": query, "limit": limit}
        if folder is not None:
            body["folder"] = folder
        if tags is not None:
            body["tags"] = tags

        resp = client.session.post(
            f"{API_URL}/search", json=body, timeout=30
        )
        assert resp.status_code == 200, (
            f"/api/search failed: {resp.status_code} {resp.text[:300]}"
        )
        return resp.json().get("results", [])
