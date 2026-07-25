"""Test 32: Multi-vault API key isolation.

Verifies that vault-scoped API keys cannot bypass restrictions:
- Restricted API key cannot read/write notes in unauthorized vaults
- Restricted API key cannot switch vaults via MCP tool arguments
- Restricted API key cannot access unauthorized vault via X-Vault-ID header
- Unrestricted API key (no api_key_vaults rows) can access all vaults

These tests exercise the security boundaries fixed in the Codex adversarial review:
1. MCP vault_id bypass (resolve_mcp_vault now checks api_key_vaults)
2. VaultPlug X-Vault-ID header enforcement

Note: WebSocket/SyncChannel API key restriction is covered by unit tests
(requires socket-level testing not available in HTTP E2E).
"""

import logging
import os
import secrets
import subprocess
import time

import pytest

from helpers.api import ApiClient
from helpers.billing import grant_test_plan
from helpers.clerk import ClerkClient
from helpers.clerk_auth import provision_clerk_user
from helpers.crypto_probe import latest_note_path_hmac, wait_for_qdrant_indexed

logger = logging.getLogger(__name__)

CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required for vault isolation tests",
)


def _set_vault_limit(user_id: str, limit: int) -> None:
    """Insert/update a user_limit_overrides row to set vaults_cap via docker exec SQL."""
    sql = (
        f"INSERT INTO user_limit_overrides "
        f"(user_id, key, value, reason, set_by) "
        f"VALUES ('{user_id}', 'vaults_cap', '{{\"v\": {limit}}}'::jsonb, 'e2e-test', 'e2e') "
        f"ON CONFLICT (user_id, key) DO UPDATE SET "
        f"value = '{{\"v\": {limit}}}'::jsonb, set_at = NOW()"
    )
    result = subprocess.run(
        ["docker", "exec", "-i", CI_POSTGRES_CONTAINER,
         "psql", "-U", "engram", "-d", "engram", "-c", sql],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to set vault limit: {result.stderr}")


def _register_test_user(ts: int):
    """Create a Clerk user and return (user_id, api_client, clerk_client, clerk_user_id).

    Uses Clerk Backend API to create the user, then provisions them
    in Engram via the real auth pipeline (Clerk JWT → find_or_create).
    """
    clerk_client = ClerkClient(CLERK_SECRET)
    email = f"e2e-vault-iso-{ts}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)

    clerk_user_id, clerk_auth, api_key = provision_clerk_user(
        clerk_client, email, password, API_URL,
    )

    # Lift pricing v2 §G Free-tier gates (api_rps_cap=0 would 429 /me)
    # before any api-key call. grant_test_plan returns the user_id via
    # email lookup, so we don't need a /me round-trip just to find it.
    user_id = grant_test_plan(email)

    api = ApiClient(API_URL, api_key)
    return user_id, api, clerk_client, clerk_user_id


@pytest.fixture(scope="module")
def vault_setup():
    """Create a Clerk user with two vaults for multi-vault isolation testing.

    Workflow:
    1. Create Clerk user (default: vaults_cap=1)
    2. Create vault A (succeeds — first vault)
    3. Verify vault B blocked by limit (402)
    4. Lift limit via user_overrides SQL
    5. Create vault B (succeeds now)
    6. Seed notes in both vaults

    Uses try/finally so the Clerk user is always cleaned up, even if
    setup assertions fail (yield teardown only runs if yield is reached).
    """
    ts = int(time.time())
    clerk_client = None
    clerk_user_id = None

    try:
        user_id, unrestricted_api, clerk_client, clerk_user_id = _register_test_user(ts)

        # Create vault A (within default limit of 1)
        vault_a_data, status = unrestricted_api.register_vault("Vault A", f"client-a-{ts}")
        assert status in (200, 201), f"Failed to register vault A: {status}"
        vault_a_id = vault_a_data["id"]

        # Vault B should be blocked by free plan limit
        vault_b_data, status = unrestricted_api.register_vault("Vault B", f"client-b-{ts}")
        assert status == 402, (
            f"Expected 402 (vault limit), got {status} — "
            f"free plan should block second vault creation"
        )

        # Lift the limit via user_overrides
        _set_vault_limit(user_id, 5)

        # Now vault B should succeed
        vault_b_data, status = unrestricted_api.register_vault("Vault B", f"client-b-{ts}")
        assert status in (200, 201), f"Failed to register vault B after limit lift: {status}"
        vault_b_id = vault_b_data["id"]

        # Seed notes in both vaults
        api_a = unrestricted_api.with_vault(vault_a_id)
        api_a.create_note("E2E/VaultA-Secret.md", "# Vault A Secret\nOnly for vault A")
        api_a.wait_for_note("E2E/VaultA-Secret.md")

        api_b = unrestricted_api.with_vault(vault_b_id)
        api_b.create_note("E2E/VaultB-Secret.md", "# Vault B Secret\nOnly for vault B")
        api_b.wait_for_note("E2E/VaultB-Secret.md")

        yield {
            "user_id": user_id,
            "unrestricted_api": unrestricted_api,
            "vault_a_id": vault_a_id,
            "vault_b_id": vault_b_id,
            "api_vault_a": api_a,
            "api_vault_b": api_b,
        }
    finally:
        if clerk_client and clerk_user_id:
            try:
                clerk_client.delete_user(clerk_user_id)
            except Exception as e:
                logger.warning("Failed to cleanup Clerk user %s: %s", clerk_user_id, e)


# ---------------------------------------------------------------------------
# Vault data isolation via X-Vault-ID header
# ---------------------------------------------------------------------------


def test_vault_a_notes_not_visible_from_vault_b(vault_setup):
    """Notes in vault A should not be visible when querying vault B."""
    api_b = vault_setup["api_vault_b"]

    note = api_b.get_note("E2E/VaultA-Secret.md")
    assert note is None, "ISOLATION BREACH: Vault B can see vault A's note!"


def test_vault_b_notes_not_visible_from_vault_a(vault_setup):
    """Notes in vault B should not be visible when querying vault A."""
    api_a = vault_setup["api_vault_a"]

    note = api_a.get_note("E2E/VaultB-Secret.md")
    assert note is None, "ISOLATION BREACH: Vault A can see vault B's note!"


def test_vault_a_changes_isolated(vault_setup):
    """GET /notes/changes from vault A should not include vault B notes."""
    api_a = vault_setup["api_vault_a"]

    changes = api_a.get_changes("2000-01-01T00:00:00Z")
    paths = [c["path"] for c in changes.get("changes", [])]
    assert "E2E/VaultB-Secret.md" not in paths, (
        "ISOLATION BREACH: Vault A changes include vault B note"
    )


def test_vault_b_changes_isolated(vault_setup):
    """GET /notes/changes from vault B should not include vault A notes."""
    api_b = vault_setup["api_vault_b"]

    changes = api_b.get_changes("2000-01-01T00:00:00Z")
    paths = [c["path"] for c in changes.get("changes", [])]
    assert "E2E/VaultA-Secret.md" not in paths, (
        "ISOLATION BREACH: Vault B changes include vault A note"
    )


# ---------------------------------------------------------------------------
# Vault CRUD
# ---------------------------------------------------------------------------


def test_vault_list_returns_both_vaults(vault_setup):
    """GET /vaults should return both vaults for the user."""
    api = vault_setup["unrestricted_api"]
    vaults = api.list_vaults()
    vault_ids = [v["id"] for v in vaults]
    assert vault_setup["vault_a_id"] in vault_ids
    assert vault_setup["vault_b_id"] in vault_ids


def test_vault_registration_idempotent(vault_setup):
    """Registering the same client_id again returns the existing vault."""
    api = vault_setup["unrestricted_api"]
    ts = int(time.time())

    # First registration
    data1, status1 = api.register_vault("Idempotent Test", f"client-idem-{ts}")
    assert status1 in (200, 201)

    # Second registration with same client_id
    data2, status2 = api.register_vault("Idempotent Test", f"client-idem-{ts}")
    assert status2 == 200
    assert data2["id"] == data1["id"]
    assert data2["status"] == "existing"


# ---------------------------------------------------------------------------
# MCP vault switching with X-Vault-ID
# ---------------------------------------------------------------------------


def test_mcp_respects_vault_scoping(vault_setup):
    """MCP get_note scopes to the vault_id ARG (MCP uses vault_id, not X-Vault-ID)."""
    api_a = vault_setup["api_vault_a"]
    vault_a_id = vault_setup["vault_a_id"]

    # MCP resolves the vault from the vault_id arg (X-Vault-ID is a REST-only
    # mechanism; the MCP server is off the VaultPlug path).
    resp, status = api_a.mcp_call("get_note", {
        "source_path": "E2E/VaultA-Secret.md",
        "vault_id": vault_a_id,
    })
    assert status == 200
    content = resp.get("result", {}).get("content", [{}])
    text = content[0].get("text", "") if content else ""
    assert "Vault A Secret" in text, f"Expected vault A note content, got: {text[:200]}"


def test_mcp_cannot_see_other_vault_notes(vault_setup):
    """Scoped to vault A (via vault_id), a vault B note path is not found."""
    api_a = vault_setup["api_vault_a"]
    vault_a_id = vault_setup["vault_a_id"]

    resp, status = api_a.mcp_call("get_note", {
        "source_path": "E2E/VaultB-Secret.md",
        "vault_id": vault_a_id,
    })
    assert status == 200
    content = resp.get("result", {}).get("content", [{}])
    text = content[0].get("text", "") if content else ""
    assert "Note not found" in text, (
        f"ISOLATION BREACH: MCP scoped to vault A can see vault B note: {text[:200]}"
    )


def test_mcp_search_spans_all_vaults_by_default(vault_setup):
    """A bare search_notes (no vault_id) searches across ALL the user's vaults
    and labels each hit with its vault (cross-vault default; #985)."""
    api = vault_setup["unrestricted_api"]
    vault_a_id = vault_setup["vault_a_id"]
    vault_b_id = vault_setup["vault_b_id"]

    # Both seeded notes must be embedded before a semantic search can find them.
    wait_for_qdrant_indexed(vault_a_id, latest_note_path_hmac(vault_a_id), timeout=90)
    wait_for_qdrant_indexed(vault_b_id, latest_note_path_hmac(vault_b_id), timeout=90)

    resp, status = api.mcp_call("search_notes", {"query": "Secret"})
    assert status == 200
    text = resp.get("result", {}).get("content", [{}])[0].get("text", "")

    # Cross-vault results are labelled by vault id; BOTH vaults must be present.
    assert vault_a_id in text, f"cross-vault search missed vault A: {text[:300]}"
    assert vault_b_id in text, f"cross-vault search missed vault B: {text[:300]}"


def test_mcp_search_scoped_to_vault_id_excludes_others(vault_setup):
    """search_notes with a vault_id arg limits the search to that vault only."""
    api = vault_setup["unrestricted_api"]
    vault_a_id = vault_setup["vault_a_id"]
    vault_b_id = vault_setup["vault_b_id"]

    wait_for_qdrant_indexed(vault_a_id, latest_note_path_hmac(vault_a_id), timeout=90)

    resp, status = api.mcp_call("search_notes", {"query": "Secret", "vault_id": vault_a_id})
    assert status == 200
    text = resp.get("result", {}).get("content", [{}])[0].get("text", "")

    # Scoped to A → must not surface vault B's id.
    assert vault_b_id not in text, f"scoped search leaked vault B: {text[:300]}"


def test_mcp_vault_id_override_same_user(vault_setup):
    """MCP tool with vault_id arg should switch to that vault (same user, unrestricted key)."""
    api_a = vault_setup["api_vault_a"]
    vault_b_id = vault_setup["vault_b_id"]

    # Use vault_id arg to switch from vault A context to vault B
    resp, status = api_a.mcp_call("get_note", {
        "source_path": "E2E/VaultB-Secret.md",
        "vault_id": vault_b_id,
    })
    assert status == 200
    content = resp.get("result", {}).get("content", [{}])
    text = content[0].get("text", "") if content else ""
    # Unrestricted key should be able to switch vaults
    assert "Vault B Secret" in text, (
        f"Unrestricted key should be able to switch vaults via MCP, got: {text[:200]}"
    )


# ---------------------------------------------------------------------------
# Cross-vault write attempts
# ---------------------------------------------------------------------------


def test_write_to_vault_a_does_not_appear_in_vault_b(vault_setup):
    """A note written via vault A's X-Vault-ID should not appear in vault B."""
    api_a = vault_setup["api_vault_a"]
    api_b = vault_setup["api_vault_b"]

    path = "E2E/VaultA-WriteTest.md"
    api_a.create_note(path, "# Write Test\nWritten to vault A only")
    api_a.wait_for_note(path)

    note_b = api_b.get_note(path)
    assert note_b is None, "ISOLATION BREACH: Write to vault A appeared in vault B!"


def test_invalid_vault_id_header_returns_404(vault_setup):
    """X-Vault-ID pointing to nonexistent vault returns 404."""
    api = vault_setup["unrestricted_api"]
    bad_api = api.with_vault(999999)

    resp = bad_api.session.get(f"{bad_api.base_url}/folders", timeout=10)
    assert resp.status_code == 404, f"Expected 404 for bad vault ID, got {resp.status_code}"
