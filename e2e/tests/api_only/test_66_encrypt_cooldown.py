"""Test 66: Per-user encryption-toggle cooldown end-to-end.

Proves that:
  1. With `users.encryption_toggle_cooldown_days = NULL` (the default), the
     user can re-toggle encryption immediately — no 429.
  2. With `users.encryption_toggle_cooldown_days = 7` (hosted-tier example),
     a second toggle inside the window returns 429 with a `retry_after` body.
  3. Backdating `vaults.last_toggle_at` past the window lets the next toggle
     succeed again.

Pairs with the unit-level cooldown matrix in
`test/engram/crypto/encrypt_vault_test.exs` — those tests cover the pure
predicate; this one proves the controller/JSON contract that the plugin
relies on (`cooldown_days` field, 429 status, `retry_after` payload).
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone

import pytest

from helpers.crypto_probe import (
    backdate_last_toggle,
    get_user_id_for_vault,
    set_user_cooldown_days,
    wait_for_encryption_status,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.fixture
def reset_cooldown(api_sync):
    """Restore vault to 'none' and clear the user's cooldown_days so other
    tests start from the documented default."""
    yield
    vaults = api_sync.list_vaults()
    if not vaults:
        return
    vault = vaults[0]
    vault_id = vault["id"]
    user_id = get_user_id_for_vault(vault_id)

    # Best-effort: rewind cooldown so we can decrypt-and-cancel back to 'none'.
    set_user_cooldown_days(user_id, None)
    backdate_last_toggle(vault_id, days=8)

    resp = api_sync.session.get(
        f"{API_URL}/vaults/{vault_id}/encryption_progress", timeout=5
    )
    if not resp.ok:
        return
    status = resp.json().get("status")
    if status == "encrypting":
        wait_for_encryption_status(api_sync, vault_id, "encrypted", timeout=60)
        status = "encrypted"
    if status == "encrypted":
        # Decrypt-request → cancel cycles back to "encrypted" without waiting
        # 24h, but we want "none" — fall through to the request_decrypt path.
        api_sync.session.post(f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10)
        from helpers.crypto_probe import backdate_decrypt_requested

        backdate_decrypt_requested(vault_id, hours=25)
        wait_for_encryption_status(api_sync, vault_id, "none", timeout=60)
        backdate_last_toggle(vault_id, days=8)
        set_user_cooldown_days(user_id, None)


@pytest.mark.skip(
    reason="Phase B.3: vault encrypt/decrypt toggle retires in B.4 — "
    "DecryptVault writes back to plaintext columns that no longer exist, "
    "so the toggle teardown can never reach status='none'. Re-enable as "
    "part of the B.4 mandatory-encryption work or delete with the toggle."
)
class TestEncryptCooldown:
    """Per-user cooldown gate on the /encrypt endpoint."""

    def test_null_cooldown_allows_immediate_retoggle(
        self, api_sync, reset_cooldown
    ):
        vaults = api_sync.list_vaults()
        assert vaults
        vault_id = vaults[0]["id"]
        user_id = get_user_id_for_vault(vault_id)
        vault_client = api_sync.with_vault(vault_id)

        # Default state: NULL cooldown, vault in "none".
        set_user_cooldown_days(user_id, None)
        backdate_last_toggle(vault_id, days=8)
        wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202
        assert resp.json()["vault"]["cooldown_days"] is None, (
            "vault JSON should expose the user's effective cooldown_days; "
            "plugin reads this to decide whether to surface 'next toggle in N days'"
        )

    def test_cooldown_returns_429_with_retry_after(self, api_sync, reset_cooldown):
        vaults = api_sync.list_vaults()
        assert vaults
        vault_id = vaults[0]["id"]
        user_id = get_user_id_for_vault(vault_id)
        vault_client = api_sync.with_vault(vault_id)

        # Start clean: NULL cooldown lets us encrypt successfully.
        set_user_cooldown_days(user_id, None)
        backdate_last_toggle(vault_id, days=8)
        wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202
        wait_for_encryption_status(vault_client, vault_id, "encrypted", timeout=30)

        # Now flip cooldown_days = 7 and try to decrypt — last_toggle_at is
        # the encrypt we just did, well within the 7-day window.
        set_user_cooldown_days(user_id, 7)

        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10
        )
        assert resp.status_code == 429, (
            f"second toggle within 7-day cooldown should be 429, "
            f"got {resp.status_code}: {resp.text!r}"
        )
        body = resp.json()
        assert "retry_after" in body, (
            "429 body must include retry_after so the plugin can render the "
            "'next toggle available' hint without a second round trip"
        )
        # retry_after is an ISO-8601 timestamp computed as
        # `last_toggle_at + cooldown_days`. Confirm it parses, lies in the
        # future, and is within the 7-day window we just configured.
        retry_at = datetime.fromisoformat(body["retry_after"].replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        assert retry_at > now, (
            f"retry_after should be in the future; got {retry_at} vs now={now}"
        )
        assert retry_at - now <= timedelta(days=7, seconds=60), (
            f"retry_after should be within 7 days from now; got {retry_at - now}"
        )

    def test_backdating_last_toggle_unblocks_next_toggle(
        self, api_sync, reset_cooldown
    ):
        vaults = api_sync.list_vaults()
        assert vaults
        vault_id = vaults[0]["id"]
        user_id = get_user_id_for_vault(vault_id)
        vault_client = api_sync.with_vault(vault_id)

        set_user_cooldown_days(user_id, 7)
        backdate_last_toggle(vault_id, days=8)
        wait_for_encryption_status(vault_client, vault_id, "none", timeout=5)

        # 8 days ago > 7-day window → should succeed.
        resp = vault_client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202, (
            f"encrypt should succeed once last_toggle_at is past the 7-day window; "
            f"got {resp.status_code}: {resp.text!r}"
        )
        assert resp.json()["vault"]["cooldown_days"] == 7
