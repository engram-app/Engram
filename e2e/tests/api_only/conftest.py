"""Fixtures for API-only tests (no Obsidian needed).

These tests run during the Obsidian boot gap in CI. The freshly
provisioned users have no vault yet (Obsidian hasn't registered
one), so we create them here to satisfy VaultPlug.

Provider-agnostic: works with both Clerk and local auth.
"""

import pytest


@pytest.fixture(scope="session", autouse=True)
def ensure_vaults(api_sync, api_iso):
    """Create default vaults so vault-scoped endpoints don't 404."""
    api_sync.create_vault("e2e-api-only")
    api_iso.create_vault("e2e-api-only-iso")


@pytest.fixture(scope="session", autouse=True)
async def _assert_plugin_surfaces():
    """Override the parent conftest's plugin-surface assertion.

    api_only intentionally runs during the Obsidian boot gap — no plugin
    is installed and no ``cdp_a`` is available, so letting the parent
    fixture pull ``cdp_a`` explodes with ``FileNotFoundError: plugin/main.js``
    before any API test can run.  Override as a no-op here so the assert
    only fires for tests that actually drive Obsidian.
    """
    return
