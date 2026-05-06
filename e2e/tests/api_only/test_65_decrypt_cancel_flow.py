"""Test 65: Cancel a pending decrypt, vault stays encrypted.

Drives the encrypt → decrypt-request → cancel-decrypt path through real
HTTP and verifies vault state transitions match what the plugin UI will
render: `none` → `encrypting`/`encrypted` → `decrypt_pending` → `encrypted`.

This pairs with test_64 (which exercises the full encrypt/decrypt backfill
cycle) — here the focus is the cancel path, which only test_64's unit-test
counterpart covers today.
"""

from __future__ import annotations

import logging
import os

import pytest

from helpers.crypto_probe import (
    backdate_decrypt_requested,
    backdate_last_toggle,
    wait_for_encryption_status,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.fixture
def reset_vault_encryption(api_sync):
    """Restore the shared vault to 'none' so re-runs and downstream tests start clean."""
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
    if status in ("encrypted", "encrypting", "decrypt_pending"):
        if status == "encrypting":
            wait_for_encryption_status(api_sync, vault_id, "encrypted", timeout=60)
        if status == "decrypt_pending":
            api_sync.session.delete(
                f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10
            )
            wait_for_encryption_status(api_sync, vault_id, "encrypted", timeout=10)
        backdate_last_toggle(vault_id, days=8)
        api_sync.session.post(f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10)
        backdate_decrypt_requested(vault_id, hours=25)
        wait_for_encryption_status(api_sync, vault_id, "none", timeout=60)
        backdate_last_toggle(vault_id, days=8)


@pytest.mark.skip(
    reason="Phase B.3: vault encrypt/decrypt toggle retires in B.4 — "
    "DecryptVault writes back to plaintext columns that no longer exist, "
    "so the toggle teardown can never reach status='none'. Re-enable as "
    "part of the B.4 mandatory-encryption work or delete with the toggle."
)
class TestDecryptCancelFlow:
    """Cancel a pending decrypt and confirm the vault returns to 'encrypted'."""

    def test_cancel_pending_decrypt(self, api_sync, reset_vault_encryption):
        vaults = api_sync.list_vaults()
        assert vaults
        vault_id = vaults[0]["id"]
        vault_client = api_sync.with_vault(vault_id)

        wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202
        body = resp.json()["vault"]
        assert "cooldown_days" in body, "vault JSON should expose cooldown_days"

        wait_for_encryption_status(vault_client, vault_id, "encrypted", timeout=30)

        # Default user has no cooldown, but other tests may share this vault and
        # leave last_toggle_at recent — backdate so the decrypt request lands
        # cleanly even if cooldown_days is set in the future.
        backdate_last_toggle(vault_id, days=8)

        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10
        )
        assert resp.status_code == 202
        body = resp.json()["vault"]
        assert body["encryption_status"] == "decrypt_pending"
        assert body["decrypt_requested_at"] is not None

        # Cancel before the 24h scheduler window elapses
        resp = vault_client.session.delete(
            f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10
        )
        assert resp.status_code == 202
        body = resp.json()["vault"]
        assert body["encryption_status"] == "encrypted"
        assert body["decrypt_requested_at"] is None

        # Confirm via progress endpoint that we settled in 'encrypted'
        resp = vault_client.session.get(
            f"{API_URL}/vaults/{vault_id}/encryption_progress", timeout=5
        )
        assert resp.ok
        assert resp.json()["status"] == "encrypted"
