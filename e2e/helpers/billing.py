"""E2E billing helpers — grant plan limits to test users.

Pricing v2 §G gates default Free-tier values that block API-key traffic
(`api_rps_cap=0` → 429, `api_write_enabled=false` → 403). The unit-test
suite has `EngramWeb.ConnCase.grant_api_write!/1` for the same problem;
this is the e2e equivalent. Insert overrides via SQL keyed on email so
no API hit is required (the first /me would itself 429).
"""

import json
import logging
import os
import subprocess

logger = logging.getLogger(__name__)

CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

# Mirror EngramWeb.ConnCase.grant_api_write!/1 — lift the §G gates that
# block API-key-authed traffic. Keep this minimal: only override the keys
# whose Free defaults would prevent e2e from exercising the surface.
# Tests that need to assert a specific gate (e.g. test_32 vault cap) set
# their own override on top via their own SQL helper.
#
# -1 is the canonical "unlimited" sentinel (cap_json/-1 → null on the
# wire; check_limit/-1 → :ok). A nil-valued override would fall through
# to plan/tier defaults via wrap_lookup, so it does NOT unlock anything.
TEST_USER_OVERRIDES = {
    "api_write_enabled": True,
    "api_rps_cap": 1000,
    "obsidian_connections_cap": -1,
    "mcp_connections_cap": -1,
    # Free-tier launch (§G) gates attachments behind `attachments_enabled`
    # which defaults false for Free. Existing attachment-bearing e2e tests
    # (test_19 write isolation, test_40 storage endpoint, test_70 MIME
    # whitelist) provision via `sync_user`/`isolation_user` fixtures which
    # already call grant_test_plan; flipping this true here lifts the gate
    # for all such tests without per-test edits. Tests that need to assert
    # the 402 (e.g. test_73 Free attachment block) intentionally do NOT
    # call grant_test_plan, so this override does not leak to them.
    "attachments_enabled": True,
    # Grant the full MimeWhitelist surface (PNG, PDF, the .exe rejection
    # assertions, etc.). Was `"attachments_text_only": False`, which only
    # worked through the restriction-shaped alias that the pricing-v2 contract
    # step removed — the grant-shaped key is now the only spelling. test_73
    # leaves this alone to assert the 402.
    "attachments_all_types": True,
    # Free-tier `concurrent_devices` defaults to 1 (§G). test_49's
    # cross-auth scenario provisions OAuth on the same user that already
    # holds an API key session, which trips EnforceDeviceCap at the
    # device-authorize step (`Device authorize failed: 402`). -1 lifts
    # the cap to unlimited. Tests that need to assert the 1-device gate
    # (test_71 connections cap) do NOT call grant_test_plan.
    "concurrent_devices": -1,
    # Free is keyword-only (BM25 over Qdrant sparse vectors) and writes no
    # dense vector at all, so any test that queries the DENSE index — test_50's
    # binary-quantization round-trip is the direct one — gets 0 results without
    # this. Tests that need to assert the Free keyword-only behaviour do NOT
    # call grant_test_plan, so this does not leak to them.
    "search_semantic_enabled": True,
    # Free indexes only its first 2,000 notes. -1 lifts the cap so a long-lived
    # e2e user that accumulates notes across a run cannot silently stop being
    # searchable partway through the suite.
    "indexed_notes_cap": -1,
}


def grant_test_plan(email: str) -> str:
    """Grant Pro-tier-equivalent overrides to the user with this email.

    Returns the resolved user_id (uuid string, useful for tests that
    need it for follow-up SQL). Raises if the user does not exist or
    the docker exec fails.
    """
    values_sql = ", ".join(
        f"((SELECT id FROM users WHERE email = '{email}'), '{k}', "
        f"'{json.dumps({'v': v})}'::jsonb, 'e2e-test', 'e2e')"
        for k, v in TEST_USER_OVERRIDES.items()
    )

    sql = (
        "INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES {values_sql} "
        "ON CONFLICT (user_id, key) DO UPDATE "
        "SET value = EXCLUDED.value, set_at = NOW(); "
        f"SELECT id FROM users WHERE email = '{email}';"
    )

    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"grant_test_plan({email}) failed: {result.stderr.strip()}"
        )

    # Last non-empty line is the user_id (from the trailing SELECT)
    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    if not lines:
        raise RuntimeError(
            f"grant_test_plan({email}): no user_id returned — user may not exist yet"
        )
    user_id = lines[-1].strip()
    logger.info("Granted e2e plan overrides to user %s (id=%s)", email, user_id)
    return user_id


def grant_vault_headroom(email: str) -> None:
    """Lift `vaults_cap` for ONE user, for a test that legitimately needs a
    second vault (test_98 re-syncs one local vault into a fresh server one).

    Deliberately NOT in `TEST_USER_OVERRIDES`: that dict is applied by every
    `grant_test_plan` caller, and `test_32_vault_api_key_isolation` asserts the
    Free plan BLOCKS a second vault. Granting it globally turned that test's
    expected 402 into a 201 — the same leak the comments in that dict warn
    about, so the fix is opt-in rather than a wider default.
    """
    sql = (
        "INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE email = '{email}'), 'vaults_cap', "
        f"'{json.dumps({'v': -1})}'::jsonb, 'e2e-test', 'e2e') "
        "ON CONFLICT (user_id, key) DO UPDATE "
        "SET value = EXCLUDED.value, set_at = NOW();"
    )
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"grant_vault_headroom({email}) failed: {result.stderr.strip()}"
        )
    logger.info("Lifted vaults_cap for %s", email)
