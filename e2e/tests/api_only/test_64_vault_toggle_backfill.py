"""Test 64: Full vault toggle backfill cycle via HTTP API.

Writes 3 plaintext notes → toggles encryption ON → backfill converts all
to ciphertext (probed directly in Postgres + Qdrant) → time-travels past
cooldown + 24h delay → toggles encryption OFF → backfill converts all
back to plaintext.

Proves the toggle endpoint + Oban backfill worker + decrypt worker end to end.
"""

from __future__ import annotations

import logging
import os
import time

import pytest

from helpers.crypto_probe import (
    assert_note_ciphertext_at_rest,
    assert_note_plaintext_at_rest,
    assert_qdrant_ciphertext,
    assert_qdrant_plaintext,
    backdate_decrypt_requested,
    backdate_last_toggle,
    wait_for_encryption_status,
    wait_for_qdrant_indexed,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.mark.skip(
    reason="Phase B.3: vault encrypt/decrypt toggle retires in B.4 — "
    "DecryptVault writes back to plaintext columns that no longer exist, "
    "so the toggle teardown can never reach status='none'. Re-enable as "
    "part of the B.4 mandatory-encryption work or delete with the toggle."
)
class TestVaultToggleBackfill:
    """Toggle encrypt + backfill + decrypt cycle with pre-existing plaintext notes."""

    def test_toggle_backfill_full_cycle(self, api_sync):
        vaults = api_sync.list_vaults()
        assert vaults
        vault_id = vaults[0]["id"]
        vault_client = api_sync.with_vault(vault_id)

        # Starting-state guard — fail fast if a prior test left the vault encrypted
        wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

        notes = [
            ("meeting-notes.md", "Meeting with Alice about Q2 roadmap"),
            ("ideas.md", "Idea: a search engine that forgets"),
            ("journal/2026-04-22.md", "Today I learned about envelope encryption"),
        ]

        # 1. Push 3 plaintext notes
        for path, content in notes:
            resp = vault_client.session.post(
                f"{API_URL}/notes",
                json={"path": path, "content": content, "mtime": time.time()},
                timeout=10,
            )
            assert resp.ok, f"push failed for {path}: {resp.status_code} {resp.text[:300]}"

        # 2. Baseline — plaintext at rest (DB + Qdrant)
        for path, _ in notes:
            assert_note_plaintext_at_rest(vault_id, path)
        for path, _ in notes:
            wait_for_qdrant_indexed(vault_id, path, timeout=60)
        assert_qdrant_plaintext(vault_id, min_chunks=len(notes))

        # 3. Toggle encrypt
        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202
        wait_for_encryption_status(vault_client, vault_id, "encrypted", timeout=90)

        # 4. All notes ciphertext at rest, but plaintext over the wire
        for path, content in notes:
            assert_note_ciphertext_at_rest(vault_id, path)
            got = vault_client.get_note(path)
            assert got is not None and got["content"] == content, (
                f"Post-encrypt read mismatch for {path}: {got!r}"
            )
        assert_qdrant_ciphertext(vault_id, min_chunks=len(notes))

        # 5. Time-travel past 7-day cooldown
        backdate_last_toggle(vault_id, days=8)

        # 6. Request decrypt
        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10
        )
        assert resp.status_code == 202, (
            f"decrypt request failed: {resp.status_code} {resp.text[:300]}"
        )

        # 7. Time-travel past 24h delay (both vault row + scheduled Oban job)
        backdate_decrypt_requested(vault_id, hours=25)

        # 8. Wait for scheduler pickup + decrypt backfill
        wait_for_encryption_status(vault_client, vault_id, "none", timeout=90)

        # 9. All notes plaintext at rest
        for path, content in notes:
            assert_note_plaintext_at_rest(vault_id, path)
            got = vault_client.get_note(path)
            assert got is not None and got["content"] == content
        assert_qdrant_plaintext(vault_id, min_chunks=len(notes))
