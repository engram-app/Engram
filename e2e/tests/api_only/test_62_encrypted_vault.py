"""Test 62: Encrypted vault round-trip via HTTP API with at-rest probes.

Registers a vault, enables encryption via the real toggle endpoint
(POST /api/vaults/:id/encrypt), writes a note through the HTTP API,
reads it back as plaintext, and directly probes Postgres + Qdrant
to prove the note is ciphertext at rest.

This is the acceptance test for end-to-end encryption across a real
HTTP boundary. It runs in the api_only CI job (no Obsidian, no Clerk).

Teardown is non-trivial: cooldown + 24h decrypt delay are normally
enforced, so the `reset_vault_encryption` fixture uses SQL time-travel
(same docker-exec pattern) to bypass them and restore the vault to
'none' status before the next test touches it.
"""

from __future__ import annotations

import logging
import os
import time

import pytest

from helpers.crypto_probe import (
    assert_note_ciphertext_at_rest,
    assert_qdrant_ciphertext,
    backdate_decrypt_requested,
    backdate_last_toggle,
    wait_for_encryption_status,
    wait_for_qdrant_indexed,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.fixture
def reset_vault_encryption(api_sync):
    """Teardown — put the shared vault back to 'none' status via real decrypt flow,
    bypassing cooldown and the 24h delay with SQL time-travel."""
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
        # Leave the vault ready for any subsequent test (or rerun) — the
        # POST /decrypt above reset last_toggle_at to 'now', so backdate it
        # again.
        backdate_last_toggle(vault_id, days=8)


@pytest.mark.skip(
    reason="Phase B.3: vault encrypt/decrypt toggle retires in B.4 — "
    "DecryptVault writes back to plaintext columns that no longer exist, "
    "so the toggle teardown can never reach status='none'. Re-enable as "
    "part of the B.4 mandatory-encryption work or delete with the toggle."
)
class TestEncryptedVaultRoundTrip:
    """Write and read a note from an encrypted vault via HTTP, with at-rest probes."""

    def test_encrypted_vault_round_trip(self, api_sync, reset_vault_encryption):
        """Plaintext written to an encrypted vault is ciphertext at rest but
        transparent plaintext over the wire."""
        vaults = api_sync.list_vaults()
        assert vaults, f"api_sync should have pre-registered a vault; got {vaults}"
        vault_id = vaults[0]["id"]
        vault_client = api_sync.with_vault(vault_id)

        # 1. Toggle encryption via real endpoint
        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202, (
            f"encrypt failed: {resp.status_code} {resp.text[:300]}"
        )

        # 2. Wait for backfill to finish (empty vault — should be near-instant)
        wait_for_encryption_status(vault_client, vault_id, "encrypted", timeout=30)

        # 3. Write note
        plaintext = "secret diary entry — only plaintext should come back"
        note_path = "journal/today.md"
        resp = vault_client.session.post(
            f"{API_URL}/notes",
            json={"path": note_path, "content": plaintext, "mtime": time.time()},
            timeout=10,
        )
        assert resp.ok, f"upsert_note failed: {resp.status_code} {resp.text[:300]}"

        # 4. Read back — transparent decrypt returns plaintext
        note = vault_client.get_note(note_path)
        assert note is not None, f"Note not found after upsert: {note_path}"
        assert note["content"] == plaintext, (
            f"Expected plaintext content, got: {note['content'][:100]!r}"
        )

        # 5. PROBE: at-rest ciphertext in Postgres
        assert_note_ciphertext_at_rest(vault_id, note_path)

        # 6. PROBE: at-rest ciphertext in Qdrant (after embed worker)
        wait_for_qdrant_indexed(vault_id, note_path, timeout=60)
        assert_qdrant_ciphertext(vault_id, min_chunks=1)
