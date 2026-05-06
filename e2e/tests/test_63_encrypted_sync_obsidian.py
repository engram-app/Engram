"""Test 63: Obsidian plugin round-trip across an encrypted vault.

Vault A and B share one user/vault. Encryption is toggled on via the real
endpoint. A writes a file via filesystem → plugin watcher pushes to backend
→ DB + Qdrant probed for ciphertext at rest → B pulls → plaintext on disk.

Proves full plugin → HTTP → Postgres + Qdrant → HTTP → plugin chain with
encryption on.
"""

from __future__ import annotations

import logging
import os

import pytest

from helpers.crypto_probe import (
    assert_note_ciphertext_at_rest,
    assert_qdrant_ciphertext,
    backdate_decrypt_requested,
    backdate_last_toggle,
    wait_for_encryption_status,
    wait_for_qdrant_indexed,
)
from helpers.vault import read_note, write_note

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.fixture
def reset_vault_encryption(api_sync):
    """Teardown — put the vault back to 'none' state via real decrypt flow."""
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
    "part of the B.4 mandatory-encryption work or rewrite without the "
    "toggle once every vault is encrypted by default."
)
@pytest.mark.asyncio
async def test_encrypted_sync_obsidian(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, reset_vault_encryption
):
    """Plugin A pushes to encrypted vault; ciphertext at rest; plugin B pulls plaintext."""
    vaults = api_sync.list_vaults()
    assert vaults
    vault_id = vaults[0]["id"]
    vault_client = api_sync.with_vault(vault_id)

    # Starting-state guard — a prior test may have left the vault in an unexpected state
    wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

    # 1. Enable encryption (empty vault — backfill near-instant)
    resp = vault_client.session.post(
        f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
    )
    assert resp.status_code == 202, f"encrypt failed: {resp.status_code} {resp.text[:300]}"
    wait_for_encryption_status(vault_client, vault_id, "encrypted", timeout=30)

    # 2. A writes a file — plugin watcher picks it up
    path = "E2E/EncryptedSyncE2E.md"
    plaintext = "# Top Secret\nOnly cipher should appear at rest."
    write_note(vault_a, path, plaintext)

    # 3. Wait for plugin push → backend
    note = api_sync.wait_for_note(path, timeout=15)
    assert "Top Secret" in note["content"]
    assert "Only cipher" in note["content"]

    # 4. PROBE: ciphertext in Postgres
    assert_note_ciphertext_at_rest(vault_id, path)

    # 5. PROBE: ciphertext in Qdrant (after embed worker)
    wait_for_qdrant_indexed(vault_id, path, timeout=60)
    assert_qdrant_ciphertext(vault_id, min_chunks=1)

    # 6. B pulls via full sync
    await cdp_b.trigger_full_sync()

    # 7. B's filesystem has plaintext
    b_content = read_note(vault_b, path)
    assert "Top Secret" in b_content, "B did not receive A's note as plaintext"
    assert "Only cipher" in b_content
