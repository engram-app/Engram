"""Pytest fixtures for Engram E2E tests.

Three Obsidian instances:
- A + B: same user (sync pair — proves two-machine sync)
- C: different user (proves multi-tenant isolation)

Auth is provider-agnostic: AuthProvider abstracts Clerk vs local
registration. All downstream fixtures receive an API key regardless
of which provider bootstrapped the user.

All fixtures are session-scoped because Obsidian startup takes ~30s (AppImage
extraction + plugin load). Each test uses unique file paths to avoid
cross-test interference. Per-test vault cleanup is avoided because deleting
files triggers the plugin's file watcher, causing unexpected sync events.
"""

from __future__ import annotations

import logging
import os
import secrets
from datetime import datetime
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.auth_provider import get_auth_provider, ClerkAuthProvider
from helpers.cdp import CdpClient
from helpers.cleanup import cleanup_test_data, cleanup_vaults
from helpers.obsidian import ObsidianInstance


logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
PLUGIN_SRC = Path(os.environ.get("ENGRAM_PLUGIN_SRC", Path(__file__).parent.parent / "plugin"))
OBSIDIAN_BIN = Path.home() / "Applications" / "Obsidian.AppImage"

def _worker_index() -> int:
    """xdist worker number (0 for master / serial runs)."""
    worker = os.environ.get("PYTEST_XDIST_WORKER", "gw0")
    return int(worker[2:]) if worker.startswith("gw") else 0


_WORKER = _worker_index()

# --------------------------------------------------------------------------
# Worker-stride constants (single source of truth)
#
# Each worker runs INSTANCES_PER_WORKER Obsidian instances (A, B, C).
# Each instance needs its own CDP port and Xvfb display.
# To keep workers non-overlapping, we stride ports/displays by the number
# of instances per worker. Keeping _PORT_STRIDE == _DISPLAY_STRIDE ==
# INSTANCES_PER_WORKER means bumping instance count updates both in one place.
# --------------------------------------------------------------------------
INSTANCES_PER_WORKER = 3
_PORT_STRIDE = INSTANCES_PER_WORKER
_DISPLAY_STRIDE = INSTANCES_PER_WORKER


def _worker_port(name: str, legacy_default: str) -> int:
    """Prefer per-worker env var (E2E_CDP_PORT_A_W1), fall back to base + stride.

    CI allocates 6 free ports and exports them as E2E_CDP_PORT_{A,B,C}_W{0,1}
    so no two workers collide even when dynamic allocation is non-contiguous.
    Serial / local runs fall back to the base env var + worker*stride.
    """
    scoped = os.environ.get(f"{name}_W{_WORKER}")
    if scoped:
        return int(scoped)
    base = int(os.environ.get(name) or legacy_default)
    return base + _WORKER * _PORT_STRIDE


# Dynamic ports/paths for parallel CI runs (defaults match legacy hardcoded values)
VAULT_PREFIX = os.environ.get("E2E_VAULT_PREFIX", "/tmp/e2e-vault")
CONFIG_PREFIX = os.environ.get("E2E_CONFIG_PREFIX", "/tmp/e2e-obsidian-config")
CDP_PORT_A = _worker_port("E2E_CDP_PORT_A", "9250")
CDP_PORT_B = _worker_port("E2E_CDP_PORT_B", "9251")
CDP_PORT_C = _worker_port("E2E_CDP_PORT_C", "9252")
DISPLAY_BASE = int(os.environ.get("E2E_DISPLAY_BASE") or "99") - _WORKER * _DISPLAY_STRIDE

# Lowest display this worker will use (B=base-1, C=base-2 → base - (INSTANCES_PER_WORKER - 1)).
# Must stay ≥ 1 (Xvfb display :0 is reserved for the host X server if any).
_min_display = DISPLAY_BASE - (INSTANCES_PER_WORKER - 1)
assert _min_display >= 1, (
    f"DISPLAY_BASE={DISPLAY_BASE} too low for worker {_WORKER}: "
    f"would use display :{_min_display}. "
    f"Raise E2E_DISPLAY_BASE in CI (currently the floor is worker*_DISPLAY_STRIDE + INSTANCES_PER_WORKER)."
)

if _WORKER > 0:
    VAULT_PREFIX = f"{VAULT_PREFIX}-w{_WORKER}"
    CONFIG_PREFIX = f"{CONFIG_PREFIX}-w{_WORKER}"


# ---------------------------------------------------------------------------
# Unique timestamp for this test run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ts():
    """Per-worker unique timestamp so two workers never pick the same email."""
    return f"{datetime.now().strftime('%Y%m%d%H%M%S%f')}w{_WORKER}"


# ---------------------------------------------------------------------------
# Auth provider (unified — works with both Clerk and local)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def auth_provider():
    """Unified auth provider based on AUTH_PROVIDER env var.

    The nuclear `cleanup_all_e2e_users()` sweep only runs on worker 0.
    Under xdist, a non-zero worker racing this against worker 0 would
    delete the other worker's freshly provisioned users. Orphan cleanup
    across runs still happens via the standalone
    `e2e/scripts/cleanup_clerk_users.py` tool.
    """
    provider = get_auth_provider(API_URL)
    if _WORKER == 0:
        provider.cleanup_all_e2e_users()
    return provider


@pytest.fixture(scope="session")
def clerk_client(auth_provider):
    """Clerk Backend API client — only available when AUTH_PROVIDER=clerk.

    Used by Clerk-specific tests (OAuth device flow, cross-auth sync).
    Returns None when running with local auth.
    """
    if isinstance(auth_provider, ClerkAuthProvider):
        return auth_provider.clerk_client
    return None


# ---------------------------------------------------------------------------
# Users (provider-agnostic)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_user(ts, auth_provider):
    """Shared user for Obsidian A + B.

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-sync-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    return email, provider_user_id, api_key


@pytest.fixture(scope="session")
def isolation_user(ts, auth_provider):
    """Separate user for Obsidian C (multi-tenant isolation).

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-iso-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    return email, provider_user_id, api_key


# ---------------------------------------------------------------------------
# Obsidian instances
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_client_id(ts):
    """Shared client_id so A and B register the same server vault."""
    return f"e2e-sync-pair-{ts}"


@pytest.fixture(scope="session")
def iso_client_id(ts):
    """Stable client_id for the isolation user's single vault.

    Giving Obsidian C a deterministic client_id lets api_iso idempotently
    upsert the same vault via /vaults/register without tripping the
    max_vaults limit (which would fire if we created two distinct vaults).
    """
    return f"e2e-iso-pair-{ts}"


@pytest.fixture(scope="session")
def obsidian_a(sync_user, sync_client_id):

    inst = ObsidianInstance(
        name="A",
        vault_path=Path(f"{VAULT_PREFIX}-a"),
        cdp_port=CDP_PORT_A,
        display=f":{DISPLAY_BASE}",
        api_url=API_URL,
        api_key=sync_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-a"),
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_b(sync_user, sync_client_id):
    """Same user as A — proves two-machine sync."""

    inst = ObsidianInstance(
        name="B",
        vault_path=Path(f"{VAULT_PREFIX}-b"),
        cdp_port=CDP_PORT_B,
        display=f":{DISPLAY_BASE - 1}",
        api_url=API_URL,
        api_key=sync_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-b"),
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_c(isolation_user, iso_client_id):
    """Different user — proves multi-tenant isolation."""

    inst = ObsidianInstance(
        name="C",
        vault_path=Path(f"{VAULT_PREFIX}-c"),
        cdp_port=CDP_PORT_C,
        display=f":{DISPLAY_BASE - 2}",
        api_url=API_URL,
        api_key=isolation_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=iso_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-c"),
    )
    inst.start()
    yield inst
    inst.stop()


# ---------------------------------------------------------------------------
# CDP clients
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def cdp_a(obsidian_a):
    return CdpClient(port=obsidian_a.cdp_port)


@pytest.fixture(scope="session")
def cdp_b(obsidian_b):
    return CdpClient(port=obsidian_b.cdp_port)


@pytest.fixture(scope="session")
def cdp_c(obsidian_c):
    return CdpClient(port=obsidian_c.cdp_port)


# ---------------------------------------------------------------------------
# API clients (always use API key — works with any auth provider)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def api_sync(sync_user, sync_client_id):
    """API client for sync user. Uses API key (provider-agnostic).

    Upserts a vault via /vaults/register (idempotent by client_id) so
    tests that hit vault-scoped endpoints don't 404 on workers whose
    bucket never boots Obsidian A/B. Sharing sync_client_id with those
    instances means the plugin's own register later is a no-op.
    """
    api = ApiClient(API_URL, sync_user[2])
    try:
        api.register_vault(f"e2e-sync-vault-w{_WORKER}", sync_client_id)
    except Exception:
        pass
    return api


@pytest.fixture(scope="session")
def api_iso(isolation_user, iso_client_id):
    """API client for isolation user. Uses API key (provider-agnostic).

    Pre-registers the same client_id Obsidian C will use so max_vaults=1
    doesn't trip when both code paths touch the same vault.
    """
    api = ApiClient(API_URL, isolation_user[2])
    try:
        api.register_vault(f"e2e-iso-vault-w{_WORKER}", iso_client_id)
    except Exception:
        pass
    return api


# ---------------------------------------------------------------------------
# Vault paths (convenience)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def vault_a(obsidian_a):
    return obsidian_a.vault_path


@pytest.fixture(scope="session")
def vault_b(obsidian_b):
    return obsidian_b.vault_path


@pytest.fixture(scope="session")
def vault_c(obsidian_c):
    return obsidian_c.vault_path


# ---------------------------------------------------------------------------
# Session-wide cleanup (runs AFTER all tests)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def session_cleanup(request, auth_provider):
    """Cleanup runs after the entire session, regardless of pass/fail.

    Captures provider user IDs during setup (before fixtures are torn down)
    so cleanup can run safely during teardown.
    """
    provider_user_ids = []
    for fixture_name in ("sync_user", "isolation_user"):
        try:
            user_tuple = request.getfixturevalue(fixture_name)
            if user_tuple and user_tuple[1]:
                provider_user_ids.append(user_tuple[1])
        except (pytest.FixtureLookupError, pytest.skip.Exception):
            pass

    yield

    # Provider-specific cleanup (e.g., delete Clerk users)
    for uid in provider_user_ids:
        auth_provider.cleanup_user(uid)
    # DB cleanup: scoped to THIS worker's users via the w{N} ts suffix
    # so a worker finishing early doesn't delete another worker's users
    # mid-run. Emails look like e2e-sync-20260416...w{N}@example.com, so
    # `%w{N}@example.com` matches only this worker's rows.
    for domain in ("example.com", "test.local", "test.com"):
        pattern = f"e2e-%w{_WORKER}@{domain}"
        try:
            cleanup_test_data(pattern)
        except Exception as e:
            logging.getLogger(__name__).error("DB cleanup failed for %s: %s", pattern, e)
    # Vault cleanup
    cleanup_vaults()
