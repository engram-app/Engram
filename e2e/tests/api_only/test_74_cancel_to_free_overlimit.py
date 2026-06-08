"""E2E test 74 (Free-tier launch §8.4.3): Pro user cancels → flips to Free →
existing notes stay readable/deletable, new creates 402 until under cap.

Covers Phase 4 (cancel webhook → tier flip) end-to-end at the wire level:
  1. Provision a fresh user; SQL-seed an active Pro subscription.
  2. SQL-seed usage_meters.notes_count = 12_000 (over the Free
     notes_cap of 10_000).
  3. POST /webhooks/paddle with a SIGNED subscription.canceled event —
     this exercises verify_signature → upsert_from_paddle_event → the
     Subscription row flips to status=canceled, which makes
     Billing.tier/1 fall through to :free.
  4. GET /api/billing/status returns tier=free.
  5. GET /notes/changes returns the seeded notes (read still works).
  6. POST /notes for a NEW path returns 402 reason=notes_cap_exceeded.
  7. Delete enough notes via the API to drop usage under 10_000 — but
     since we never inserted real rows for the seeded count, the
     delete loop relies on a direct SQL decrement of usage_meters.
  8. POST /notes for a NEW path returns 200.

Webhook secret note:
  docker-compose.ci.yml sets PADDLE_NOTIFICATION_SECRET=pdl_ntfn_e2e_fake
  (added in this PR). The test signs its payload with the same secret.
  If you run e2e outside CI, export PADDLE_NOTIFICATION_SECRET to match.

Seed-vs-real-rows note:
  The notes_cap_exceeded path is gated by UsageMeters.notes_count/1,
  which reads from the usage_meters table — NOT from a COUNT(*) of the
  notes table. So we can put a user over-cap by writing 12_000 to that
  single integer column without bulk-inserting real notes. Step 7
  similarly decrements the meter directly (Notes.delete_note would
  fail with "note not found" on the synthetic count).

  This is intentional: the test asserts the gate behavior, not the
  meter-maintenance invariant (which is covered by unit tests in
  test/engram/notes_test.exs).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import secrets
import subprocess
import time
from datetime import datetime

import pytest
import requests

from helpers.api import ApiClient
from helpers.billing import grant_test_plan
from helpers.clerk import ClerkClient
from helpers.clerk_auth import provision_clerk_user

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
# /webhooks/paddle lives outside the /api scope.
WEBHOOK_URL = (
    API_URL[: -len("/api")] if API_URL.endswith("/api") else API_URL.rsplit("/api", 1)[0]
) + "/webhooks/paddle"

CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")
PADDLE_NOTIFICATION_SECRET = os.environ.get(
    "PADDLE_NOTIFICATION_SECRET", "pdl_ntfn_e2e_fake"
)
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required",
)

FREE_NOTES_CAP = 10_000
SEED_NOTES_COUNT = 12_000


def _ts() -> str:
    return datetime.now().strftime("%Y%m%d%H%M%S%f")


def _psql(sql: str) -> str:
    """Run a one-shot SQL against the CI postgres container, return stdout."""
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}\nSQL: {sql}")
    return result.stdout.strip()


def _seed_pro_subscription(user_id: int, sub_id: str) -> None:
    """Insert an active Pro subscription row for this user.

    Mirrors the shape Billing.upsert_from_paddle_event would write on
    a subscription.created/activated event with a Pro price.
    """
    period_end = "2026-12-31T00:00:00Z"
    sql = (
        "INSERT INTO subscriptions "
        "(user_id, paddle_customer_id, paddle_subscription_id, tier, status, "
        " current_period_end, custom_data, created_at, updated_at) "
        f"VALUES ({user_id}, 'ctm_e2e_{user_id}', '{sub_id}', 'pro', 'active', "
        f"'{period_end}', '{{}}'::jsonb, NOW(), NOW()) "
        "ON CONFLICT (user_id) DO UPDATE "
        "SET paddle_subscription_id = EXCLUDED.paddle_subscription_id, "
        "    tier = 'pro', status = 'active', updated_at = NOW()"
    )
    _psql(sql)


def _set_notes_count(user_id: int, count: int) -> None:
    """Force usage_meters.notes_count for this user.

    UsageMeters.notes_cap_reached?/2 reads from this column, so this is
    the only thing we need to tweak to push the user over cap.
    """
    sql = (
        "INSERT INTO usage_meters (user_id, notes_count, updated_at) "
        f"VALUES ({user_id}, {count}, NOW()) "
        "ON CONFLICT (user_id) DO UPDATE "
        f"SET notes_count = {count}, updated_at = NOW()"
    )
    _psql(sql)


def _sign_payload(secret: str, body: bytes) -> str:
    """Build a Paddle-style ts=<unix>;h1=<hex(hmac)> header value."""
    ts = str(int(time.time()))
    signed = f"{ts}:{body.decode()}".encode()
    mac = hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
    return f"ts={ts};h1={mac}"


def _fire_canceled_webhook(sub_id: str) -> requests.Response:
    """POST a signed subscription.canceled event to /webhooks/paddle."""
    event = {
        "event_type": "subscription.canceled",
        "data": {
            "id": sub_id,
            "status": "canceled",
            "customer_id": f"ctm_e2e_{sub_id}",
            # Items array is required by the parser but irrelevant to the
            # canceled branch — keep a Pro price to mirror reality.
            "items": [{"price": {"id": "pri_pro_monthly_test"}}],
            "current_billing_period": {"ends_at": "2026-12-31T00:00:00Z"},
        },
    }
    body = json.dumps(event).encode()
    sig = _sign_payload(PADDLE_NOTIFICATION_SECRET, body)
    return requests.post(
        WEBHOOK_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Paddle-Signature": sig,
        },
        timeout=10,
    )


def test_cancel_pro_to_free_over_limit():
    """Pro→Free flip lets reads through, blocks creates until under cap."""

    # ── 1. Provision user; resolve numeric user_id via grant_test_plan ──
    clerk = ClerkClient(CLERK_SECRET)
    email = f"e2e-cancel-free-{_ts()}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)
    _clerk_user_id, _clerk_auth, api_key = provision_clerk_user(
        clerk, email, password, API_URL,
    )
    api = ApiClient(API_URL, api_key)

    # grant_test_plan returns the user_id (does an email→id lookup) and
    # lifts §G Free defaults so the e2e harness can hit the API. The
    # caps we override don't affect notes_cap (which is what we're
    # testing); they only unblock api_write_enabled / api_rps_cap so
    # the test runner doesn't 429 itself. We DO set the Pro
    # subscription afterwards so Billing.tier/1 returns :pro until the
    # cancel webhook fires.
    user_id = grant_test_plan(email)

    # Onboarding (Free was the path; we'll overwrite to Pro next).
    api.session.post(f"{api.base_url}/onboarding/accept_free_tier", timeout=10)

    sub_id = f"sub_e2e_{_ts()}"
    _seed_pro_subscription(user_id, sub_id)

    # Sanity: tier should be :pro now.
    s_resp = api.session.get(f"{api.base_url}/billing/status", timeout=10)
    assert s_resp.status_code == 200 and s_resp.json().get("tier") == "pro", (
        f"Expected tier=pro after Pro seed; got {s_resp.status_code} {s_resp.text[:200]}"
    )

    # ── 2. Seed usage_meters.notes_count over the Free cap ──────────────
    _set_notes_count(user_id, SEED_NOTES_COUNT)

    # Create a vault so vault-scoped endpoints don't 404.
    vault_resp, vault_status = api.create_vault(f"cancel-vault-{_ts()}")
    assert vault_status in (200, 201), (
        f"vault create should succeed for Pro user; got {vault_status}: {vault_resp}"
    )
    vault_id = (vault_resp.get("vault") or {}).get("id")
    assert vault_id, f"vault response missing id: {vault_resp}"
    api_v = api.with_vault(vault_id)

    # ── 3. Fire the signed cancel webhook ───────────────────────────────
    wh_resp = _fire_canceled_webhook(sub_id)
    assert wh_resp.status_code in (200, 204), (
        f"/webhooks/paddle should 200/204 on a signed canceled event; got "
        f"{wh_resp.status_code}: {wh_resp.text[:300]}"
    )

    # ── 4. /billing/status flips to free ────────────────────────────────
    # Webhook handling is synchronous in the controller path (Billing.
    # upsert_from_paddle_event/1 returns before send_resp), so a single
    # follow-up read is enough — no polling.
    s_resp2 = api.session.get(f"{api.base_url}/billing/status", timeout=10)
    assert s_resp2.status_code == 200, s_resp2.text[:200]
    body = s_resp2.json()
    assert body.get("tier") == "free", (
        f"After subscription.canceled, tier must fall to free; got tier="
        f"{body.get('tier')!r}: {body}"
    )

    # ── 5. Reads still work — manifest reports the seeded count ─────────
    # We didn't insert real note rows, so /notes/changes won't list 12k
    # notes — what we CAN observe is that the read endpoint isn't 402'd.
    changes = api_v.get_changes(since="0")
    assert isinstance(changes.get("notes"), list), (
        f"/notes/changes should still respond with a list on Free over-cap; got: {changes}"
    )

    # ── 6. Create a new note → 402 notes_cap_exceeded ──────────────────
    over_path = f"overlimit-{_ts()}.md"
    over_resp = api_v.session.post(
        f"{api_v.base_url}/notes",
        json={"path": over_path, "content": "# Over cap", "mtime": time.time()},
        timeout=10,
    )
    assert over_resp.status_code == 402, (
        f"Over-cap Free create must 402; got {over_resp.status_code}: "
        f"{over_resp.text[:300]}"
    )
    over_body = over_resp.json()
    assert over_body.get("error") == "limit_exceeded", over_body
    assert over_body.get("reason") == "notes_cap_exceeded", over_body
    assert over_body.get("limit_key") == "notes_cap", over_body
    assert over_body.get("tier") == "free", over_body
    assert over_body.get("limit") == FREE_NOTES_CAP, over_body

    # ── 7. Drop usage below cap (synthetic — no real rows to delete) ────
    # Real delete_note would 404 on the synthetic count. The "delete
    # 2001 notes" prose in the plan maps to this single SQL update for
    # the test's purposes; the maintenance invariant (delete_note
    # decrements usage_meters by 1) is covered by unit tests.
    under_count = FREE_NOTES_CAP - 1
    _set_notes_count(user_id, under_count)

    # ── 8. Create now succeeds ──────────────────────────────────────────
    under_path = f"underlimit-{_ts()}.md"
    under_resp = api_v.session.post(
        f"{api_v.base_url}/notes",
        json={"path": under_path, "content": "# Under cap", "mtime": time.time()},
        timeout=10,
    )
    assert under_resp.status_code == 200, (
        f"Once usage drops under cap, Free create must 200; got "
        f"{under_resp.status_code}: {under_resp.text[:300]}"
    )
