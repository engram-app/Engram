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

import asyncio
import logging
import os
import secrets
from datetime import datetime
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.auth_provider import get_auth_provider, ClerkAuthProvider
from helpers.billing import grant_test_plan
from helpers.cdp import CdpClient
from helpers.cleanup import cleanup_minio_bucket, cleanup_test_data, cleanup_vaults
from helpers.obsidian import ObsidianInstance
from helpers.oauth import provision_oauth_tokens, swap_to_oauth, restore_auth, wait_for_stream


logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
# The SPA is served by the backend at the API host root (strip the `/api`
# suffix). A browser-SPA peer (helpers/web_spa.py) loads this.
SPA_URL = os.environ.get("ENGRAM_SPA_URL") or (
    API_URL[:-4] if API_URL.endswith("/api") else API_URL
)
PLUGIN_SRC = Path(os.environ.get("ENGRAM_PLUGIN_SRC", Path(__file__).parent.parent / "plugin"))
OBSIDIAN_BIN = Path.home() / "Applications" / "Obsidian.AppImage"


def pytest_configure(config):
    """Fail fast when a Clerk-shaped run is missing its secret.

    The Clerk-gated test files skip themselves when E2E_CLERK_SECRET_KEY is
    empty, so a misconfigured secret would otherwise turn ~9 files into green
    skips instead of a loud failure.
    """
    if os.environ.get("AUTH_PROVIDER") == "clerk" and not os.environ.get(
        "E2E_CLERK_SECRET_KEY"
    ):
        pytest.exit(
            "AUTH_PROVIDER=clerk but E2E_CLERK_SECRET_KEY is empty — "
            "Clerk-gated tests would silently skip. Fix the secret wiring.",
            returncode=1,
        )

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


# Per-run namespace. GITHUB_RUN_ID is unique per CI run; "local" outside CI.
# Embedded in every e2e-* email so cleanup can scope its sweep to just this
# run instead of nuking sibling runs' users mid-flight (issue #160).
_RUN_ID = os.environ.get("GITHUB_RUN_ID", "local")

# Per-JOB namespace. GITHUB_RUN_ID alone is NOT enough: all parallel jobs of
# one workflow run share it, and the worker-0 setup sweep scoped to run-only
# deleted sibling jobs' live Clerk users mid-suite (issue #869 — e2e-api's
# sweep killed e2e-clerk's users; only test_49 noticed because it is the one
# mid-suite Clerk session minter). "localjob" outside CI.
_JOB_ID = os.environ.get("GITHUB_JOB", "localjob")


# ---------------------------------------------------------------------------
# Unique timestamp for this test run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ts():
    """Per-worker, per-run unique suffix for e2e-* emails.

    Format: ``{YYYYMMDDHHMMSSffffff}r{RUN_ID}j{JOB_ID}w{WORKER}`` — the
    ``r{RUN_ID}j{JOB_ID}`` segment scopes cleanup to this CI run AND job
    (issues #160 + #869: parallel jobs share GITHUB_RUN_ID, so run-only
    scoping let one job's sweep delete a sibling job's live users).
    """
    return f"{datetime.now().strftime('%Y%m%d%H%M%S%f')}r{_RUN_ID}j{_JOB_ID}w{_WORKER}"


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
        # Scope sweep to THIS run+job namespace — never touch sibling runs'
        # OR sibling jobs' users (issues #160, #869). Orphans from crashed
        # runs are reaped out-of-band by .github/workflows/clerk-orphans.yml.
        provider.cleanup_all_e2e_users(run_id=_RUN_ID, job_id=_JOB_ID)
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
def sync_password():
    """Password for `sync_user`, exposed so a browser SPA peer can sign in.

    The Obsidian/API clients authenticate with the API key, but the SPA's
    local-auth login needs the email+password — which `sync_user` otherwise
    generated inline and discarded. Sourcing it here lets both share one user.
    """
    return secrets.token_urlsafe(32)


@pytest.fixture(scope="session")
def sync_user(ts, auth_provider, sync_password):
    """Shared user for Obsidian A + B (and the browser SPA peer).

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-sync-{ts}+clerk_test@example.com"
    provider_user_id, api_key = auth_provider.provision_user(email, sync_password)
    # Lift pricing v2 §G Free-tier defaults (api_rps_cap=0, api_write_enabled=false)
    # before any api-key-authed request hits the user — mirrors
    # EngramWeb.ConnCase.grant_api_write!/1 for the e2e layer.
    grant_test_plan(email)
    return email, provider_user_id, api_key


@pytest.fixture(scope="session")
def isolation_user(ts, auth_provider):
    """Separate user for Obsidian C (multi-tenant isolation).

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-iso-{ts}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    grant_test_plan(email)
    return email, provider_user_id, api_key


@pytest.fixture(scope="session")
def resumed_user(ts, auth_provider):
    """Dedicated user for the resumed-device pair (fresh_instance_pair).

    Kept OFF sync_user's shared vault on purpose: that vault accumulates
    every note the suite creates (~1000 by the end of a full run), and
    joining it late floods the resumed devices with a full-vault genesis
    fan-out that starves the seed-note delivery inside the 30s Phase-1
    budget (the test_82 timeout flake, Engram#977/#945). A private user +
    vault keeps the resumed pair's genesis pull near-empty, so what the
    test measures is resumed-device sync, not suite churn.

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-resumed-{ts}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    grant_test_plan(email)
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
def resumed_client_id(ts):
    """Shared client_id for the resumed-device pair's single private vault.

    ResumedA + ResumedB share it so /vaults/register upserts ONE vault
    (idempotent by client_id) — the two-device shape under test — while
    staying isolated from sync_user's accumulator vault.
    """
    return f"e2e-resumed-pair-{ts}"


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


@pytest.fixture(scope="session")
def _oauth_ws_warm(cdp_a, clerk_client):
    """Absorb the OAuth WebSocket cold-boot cost once, out of any test's
    timed connect gate.

    Evidence (CI, e2e-clerk, full suite): test_47's first OAuth test alone
    ate the whole >60s cold-boot (token refresh + getMe backoff + WS
    phx_join, under 2-worker xdist load + a second Obsidian instance
    booting) inside its own RT_TIMEOUT-bounded assertion; the very next
    OAuth test then passed in ~2s once the path was warm. Doing one
    throwaway swap/wait/restore cycle here, in fixture setup with a
    generous 120s boot budget, moves that cost out of the timed window.
    Session-scoped: runs once total, whichever of test_47/48/49 executes
    first (all three swap cdp_a to OAuth and gate on wait_for_stream).
    """
    if clerk_client is None:
        return  # local-auth run: no OAuth test will request this fixture either

    async def _warm():
        clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="warm")
        try:
            original = await swap_to_oauth(cdp_a, tokens)
            # From here on cdp_a wears the throwaway OAuth identity, whose Clerk
            # user the outer finally deletes. restore_auth MUST run and MUST
            # rebind cdp_a back to its original identity on every exit path, or
            # the session-scoped cdp_a serves the rest of the suite cross-bound
            # (or as a deleted user) and one warm-up hiccup cascades into dozens
            # of misleading "Stream not connected" failures downstream.
            warm_err: TimeoutError | None = None
            try:
                await wait_for_stream(cdp_a, timeout=120)
            except TimeoutError as e:
                warm_err = e
                # Log now: if the restore below ALSO raises, it propagates as
                # primary and the re-raise at line ~374 never runs, so this
                # would otherwise be the only trace of the warm-up timeout.
                logging.getLogger(__name__).warning(
                    "OAuth WS warm-up timed out (restoring anyway): %s", e
                )

            # Always restore, warm-up success or not. restore_auth now VERIFIES
            # the rebind and raises on a cross-bind. We do NOT swallow that: a
            # cross-bound session-scoped device poisons every later test, which
            # is strictly worse than losing the warm-up error — so a restore
            # failure is surfaced as primary (it names the real, session-level
            # problem). A generous timeout covers the cold reconnect.
            await restore_auth(cdp_a, original, verify_timeout=120)

            if warm_err is not None:
                raise TimeoutError(
                    "OAuth WS cold-boot warm-up (fixture _oauth_ws_warm) timed "
                    f"out: {warm_err}. This is one-time suite setup absorbing the "
                    "first-connect cost, not the behavior under test -- check "
                    "backend/Clerk health before assuming a real regression."
                ) from warm_err
        finally:
            clerk_client.delete_user(clerk_user_id)

    # NOTE: a temporary event loop on purpose (session fixture, sync context).
    # It leaves CdpClient._ws bound to the closed loop; the first real test's
    # _ensure_connected ping fails and reconnects -- relied-upon self-healing,
    # not an accident. Don't "fix" the first-ping failure you see in logs.
    asyncio.run(_warm())


# ---------------------------------------------------------------------------
# Resumed-device fixture (dedicated instance pair, function-scoped)
#
# A stop/mutate-data.json/restart cycle must never touch the session-scoped
# A/B/C fixtures the rest of the suite depends on, so this is its own pair on
# its own ports/displays. It runs on a PRIVATE user+vault (resumed_user /
# resumed_client_id), NOT sync_user's shared vault: that vault accumulates
# ~1000 notes over a full run, and joining it late floods the resumed devices
# with a full-vault genesis fan-out that starves the seed delivery inside the
# 30s Phase-1 budget (Engram#977/#945). ResumedA + ResumedB still share one
# client_id, so they land on ONE (near-empty) vault — the two-device shape
# under test, minus the suite churn.
# ---------------------------------------------------------------------------

RESUMED_CDP_PORT_A = _worker_port("E2E_CDP_PORT_RESUMED_A", "9350")
RESUMED_CDP_PORT_B = _worker_port("E2E_CDP_PORT_RESUMED_B", "9351")
RESUMED_DISPLAY_BASE = int(os.environ.get("E2E_DISPLAY_BASE_RESUMED") or "150") - _WORKER * 2
assert RESUMED_DISPLAY_BASE - 1 >= 1, (
    f"RESUMED_DISPLAY_BASE={RESUMED_DISPLAY_BASE} too low for worker {_WORKER}"
)


@pytest.fixture
def fresh_instance_pair(resumed_user, resumed_client_id, resumed_api):
    """Dedicated A/B-shaped instance pair for tests that stop/restart a device.

    Function-scoped so a mid-test restart can't poison the session fixtures.
    Runs on resumed_user's private vault (resumed_api pre-registers it) to
    stay off the suite's shared accumulator vault — see the block comment
    above and Engram#977/#945.
    """
    inst_a = ObsidianInstance(
        name="ResumedA",
        vault_path=Path(f"{VAULT_PREFIX}-resumed-a"),
        cdp_port=RESUMED_CDP_PORT_A,
        display=f":{RESUMED_DISPLAY_BASE}",
        api_url=API_URL,
        api_key=resumed_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=resumed_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-resumed-a"),
    )
    inst_b = ObsidianInstance(
        name="ResumedB",
        vault_path=Path(f"{VAULT_PREFIX}-resumed-b"),
        cdp_port=RESUMED_CDP_PORT_B,
        display=f":{RESUMED_DISPLAY_BASE - 1}",
        api_url=API_URL,
        api_key=resumed_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=resumed_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-resumed-b"),
    )
    inst_a.start()
    inst_b.start()
    cdp_a = CdpClient(port=inst_a.cdp_port)
    cdp_b = CdpClient(port=inst_b.cdp_port)
    try:
        yield inst_a, inst_b, cdp_a, cdp_b
    finally:
        inst_a.stop()
        inst_b.stop()


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
def sync_vault_id(api_sync, sync_client_id):
    """Server vault id the browser SPA peer targets (seeds `activeVaultId`).

    `api_sync` already registered this vault (idempotent by client_id); a
    re-register returns the same row, so we read its id here. Shape-robust:
    the response may nest the vault under `vault` or return it flat.
    """
    resp, status = api_sync.register_vault(f"e2e-sync-vault-w{_WORKER}", sync_client_id)
    vault = resp.get("vault", resp) if isinstance(resp, dict) else {}
    vid = vault.get("id") or vault.get("vault_id") or vault.get("uuid")
    assert vid, f"no vault id in /vaults/register response (status={status}): {resp}"
    return vid


@pytest.fixture
async def web(sync_user, sync_password):
    """A real headless-Chromium peer on the SPA, signed in as `sync_user`
    (same server vault as Obsidian A/B). Function-scoped: fresh tab per test."""
    from helpers.web_spa import WebSpaPeer

    peer = WebSpaPeer(SPA_URL, sync_user[0], sync_password)
    await peer.start()
    yield peer
    await peer.stop()


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


@pytest.fixture(scope="session")
def resumed_api(resumed_user, resumed_client_id):
    """API client for the resumed-device user's private vault.

    test_82 verifies resumed B's PUSH landed server-side via this client,
    so it must target the SAME (private) vault the resumed pair joins —
    not sync_user's shared accumulator vault. Pre-registers the vault so
    the plugin's own register is a no-op and vault-scoped polls don't 404.
    """
    api = ApiClient(API_URL, resumed_user[2])
    try:
        api.register_vault(f"e2e-resumed-vault-w{_WORKER}", resumed_client_id)
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
# Plugin-surface assertion (replaces per-test has_* skip guards)
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
async def _track_apikey_wipe(request):
    """After each test, log if apiKey on cdp_a went empty in mem or disk.

    PR #162 surfaced a flake where test_66/69/70 hit `apiKeyLen: 0` on
    both memory AND disk — meaning a PRIOR test wrote ``apiKey: ""`` via
    saveSettings. Memory-only diagnostic can't identify the wiper.
    This hook probes apiKey at teardown and logs WHICH test transitioned
    it from non-empty → empty. Adds ~30 ms / test that uses cdp_a.

    Skips tests that don't use cdp_a (api_only, etc.).
    """
    yield
    if "cdp_a" not in request.fixturenames:
        return
    try:
        cdp_a_val = request.getfixturevalue("cdp_a")
    except (pytest.FixtureLookupError, Exception):
        return
    try:
        state = await cdp_a_val.evaluate(
            """
            (async () => {
                const p = app.plugins.plugins['engram-vault-sync'];
                const memK = (p.settings?.apiKey || '');
                const memR = (p.settings?.refreshToken || '');
                let diskK = '', diskR = '';
                try {
                    const data = await p.loadData() || {};
                    const ds = data.settings || {};
                    diskK = ds.apiKey || '';
                    diskR = ds.refreshToken || '';
                } catch (_) {}
                return {
                    memApiKeyLen: memK.length,
                    memRefreshTokenLen: memR.length,
                    diskApiKeyLen: diskK.length,
                    diskRefreshTokenLen: diskR.length,
                };
            })()
            """,
            await_promise=True,
        )
    except Exception as e:
        logging.getLogger(__name__).warning(
            "apikey-wipe probe failed for %s: %s", request.node.nodeid, e
        )
        return
    if not isinstance(state, dict):
        return
    mem_k = state.get("memApiKeyLen", 0)
    disk_k = state.get("diskApiKeyLen", 0)
    mem_r = state.get("memRefreshTokenLen", 0)
    if mem_k == 0 and disk_k == 0 and mem_r == 0:
        logging.getLogger(__name__).error(
            "APIKEY-WIPE detected after %s — mem=%d/%d disk=%d/%d",
            request.node.nodeid, mem_k, mem_r, disk_k,
            state.get("diskRefreshTokenLen", 0),
        )


@pytest.fixture(autouse=True)
async def _isolate_offline_queue(request):
    """Reset each used instance's offline queue + issues BEFORE every test.

    Obsidian instances are session-scoped (one process per worker for the
    whole suite), but every test re-registers its vault, so settings.vaultId
    churns across tests. The offline queue keys entries by `{vaultId}:{path}`
    and flushQueue dequeues by the CURRENT settings.vaultId — so an entry
    enqueued under a prior test's vaultId can never be dequeued and lingers
    in the queue forever (`queue.size` counts entries across ALL vaultIds).

    Any offline test that doesn't fully drain leaks those orphaned entries
    into every later test; drain-to-zero tests (test_24/test_29) then fail
    with "Queue not drained" against foreign-vaultId entries they never
    created. engram#635 misdiagnosed this as an offline-flag load race and
    only stabilized the flag timing, so the failure kept recurring.

    Clearing per-test guarantees each test starts from an empty queue. Skips
    tests that don't use a CDP instance (api_only, etc.). Best-effort: an
    instance not yet booted on this worker must not fail the test, so a reset
    error is logged at debug and swallowed (no real state to corrupt).
    """
    for name in ("cdp_a", "cdp_b", "cdp_c"):
        if name not in request.fixturenames:
            continue
        try:
            cdp = request.getfixturevalue(name)
            await cdp.reset_sync_state()
        except Exception as e:  # noqa: BLE001 — best-effort pre-test isolation
            logging.getLogger(__name__).debug(
                "offline-queue reset skipped for %s/%s: %s",
                name, request.node.nodeid, e,
            )
    yield


@pytest.fixture(scope="session", autouse=True)
async def _assert_plugin_surfaces(cdp_a):
    """Hard-fail once if the plugin under test lacks required surfaces.

    Previously every Sync-Center / SyncPreview / search / command-palette /
    echo-suppression test carried its own ``pytest.skip`` autouse guard that
    asked CDP for a single ``typeof`` or ``has_command`` check.  Those guards
    were written for the era when CI shipped multiple plugin SHAs side-by-side
    and tests had to tolerate older builds. The plugin has been stable for
    months — every checked surface now ships in every build — so the guards
    became dead code that silently skipped tests when something WAS broken
    (e.g. a build that failed to expose a command would just disappear from
    the suite instead of failing).

    Single bulk probe runs once per session. If anything is missing the suite
    fails loudly with the offending names listed, which is the signal we
    actually want.  Add new entries here, not in individual test files.
    """
    await cdp_a.wait_for_plugin_ready(timeout=30)
    missing = await cdp_a.evaluate(
        """
        (() => {
            const p = app.plugins.plugins['engram-vault-sync'];
            const cmds = [
                'sync-now', 'push-all', 'pull-all', 'show-sync-log',
                'search', 'open-search-sidebar', 'open-sync-center',
            ];
            const missing = [];
            if (typeof p.markSyncGateAccepted !== 'function') missing.push('markSyncGateAccepted');
            if (typeof p.registerVault !== 'function') missing.push('plugin.registerVault');
            if (typeof p.api?.registerVault !== 'function') missing.push('api.registerVault');
            if (typeof p.syncEngine?.isRecentlyPushed !== 'function') missing.push('isRecentlyPushed');
            if (typeof p.syncEngine?.handleStreamEvent !== 'function') missing.push('handleStreamEvent');
            if (!(p.syncEngine?.syncState instanceof Map)) missing.push('syncState:Map');
            if (typeof p.settings?.conflictResolution === 'undefined') missing.push('settings.conflictResolution');
            for (const id of cmds) {
                if (!app.commands.findCommand(`engram-vault-sync:${id}`)) {
                    missing.push(`command:${id}`);
                }
            }
            const ribbon = Array.from(document.querySelectorAll('.side-dock-ribbon-action'))
                .some(el => el.getAttribute('aria-label')?.includes('Engram'));
            if (!ribbon) missing.push('ribbon');
            return missing;
        })()
        """
    )
    if missing:
        pytest.fail(
            "Plugin under test is missing required surfaces: "
            + ", ".join(missing)
            + ". Either the build is broken or the plugin lost a feature these "
              "tests rely on. Update src/, not the test."
        )


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
    # Per-run safety net: delete EVERY Clerk user this session created, not
    # just the shared sync_user/isolation_user fixtures. Individual tests
    # (billing, oauth, connections) provision their own users; without this
    # they leaked every run and only the hourly orphan reaper caught them —
    # which a heavy-CI burst outpaces, exhausting the 100-user quota and
    # 403'ing all Clerk-auth e2e. Scoped to THIS client's creations, so it
    # never races a sibling run. See helpers/clerk.py ClerkClient.cleanup_tracked.
    clerk = getattr(auth_provider, "clerk_client", None)
    if clerk is not None:
        try:
            n = clerk.cleanup_tracked()
            if n:
                logging.getLogger(__name__).info("Reaped %d tracked Clerk users", n)
        except Exception as e:
            logging.getLogger(__name__).error("Tracked Clerk cleanup failed: %s", e)
    # DB cleanup: scoped to THIS worker's users via the w{N} ts suffix
    # so a worker finishing early doesn't delete another worker's users
    # mid-run. Emails look like e2e-sync-20260416...w{N}+clerk_test@example.com
    # (the `+clerk_test` plus-tag tells Clerk dev to skip outbound email
    # delivery — see docs/context/clerk-instance-swap-gaps.md), so
    # `%w{N}+clerk_test@example.com` matches only this worker's rows.
    for domain in ("example.com", "test.local", "test.com"):
        pattern = f"e2e-%w{_WORKER}+clerk_test@{domain}"
        try:
            cleanup_test_data(pattern)
        except Exception as e:
            logging.getLogger(__name__).error("DB cleanup failed for %s: %s", pattern, e)
    # Blob cleanup — purge the MinIO bucket so per-session re-runs do not
    # accumulate orphan attachment objects. Skips silently outside CI when
    # the container name doesn't match.
    try:
        cleanup_minio_bucket()
    except Exception as e:
        logging.getLogger(__name__).error("MinIO cleanup failed: %s", e)
    # Vault cleanup
    cleanup_vaults()
