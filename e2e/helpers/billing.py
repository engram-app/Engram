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
    # Free additionally restricts attachments to text/* MIMEs via
    # `attachments_text_only`. Same logic as above — the tests granted a
    # paid plan need the full MimeWhitelist surface (PNG, PDF, the .exe
    # rejection assertions, etc.). test_73 leaves this alone to assert
    # the 402.
    "attachments_text_only": False,
    # Free-tier `concurrent_devices` defaults to 1 (§G). test_49's
    # cross-auth scenario provisions OAuth on the same user that already
    # holds an API key session, which trips EnforceDeviceCap at the
    # device-authorize step (`Device authorize failed: 402`). -1 lifts
    # the cap to unlimited. Tests that need to assert the 1-device gate
    # (test_71 connections cap) do NOT call grant_test_plan.
    "concurrent_devices": -1,
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
