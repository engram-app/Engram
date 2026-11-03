"""Staging Clerk test-user reaper: matcher + age gate.

Staging's Clerk instance (`key-longhorn-79`, also local saas-dev) had no
sweep, so ad-hoc agent/QA accounts (`<anything>+clerk_test@example.com`)
piled up. The reaper's `--target staging` mode owns those, except the
`load-sim-uNN` accounts that e2e/load/sim.py reuses across runs, and only
once BOTH creation and last activity are older than `--older-than`.
"""

import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path

from helpers.clerk_constants import is_e2e_clerk_email, is_staging_test_clerk_email

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cleanup_clerk_users.py"
_spec = importlib.util.spec_from_file_location("cleanup_clerk_users", _SCRIPT)
reaper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(reaper)

NOW = datetime(2026, 11, 2, tzinfo=timezone.utc)
WEEK = timedelta(days=7)


def _ms(delta: timedelta) -> int:
    return int((NOW - delta).timestamp() * 1000)


def _user(*emails, created=timedelta(days=30), active=None, sign_in=None):
    return {
        "id": "user_x",
        "email_addresses": [{"email_address": e} for e in emails],
        "created_at": _ms(created),
        "last_active_at": None if active is None else _ms(active),
        "last_sign_in_at": None if sign_in is None else _ms(sign_in),
    }


# ── matcher ──────────────────────────────────────────────────────────────


def test_staging_matcher_owns_tagged_agent_accounts():
    for local in ("gate-0590-a", "onbv2-3", "i18n-tester", "tabtest", "feedback-demo",
                  "oauthprobe", "qc-flows", "engram-synctest"):
        assert is_staging_test_clerk_email(f"{local}+clerk_test@example.com"), local


def test_staging_matcher_spares_load_sim_accounts():
    assert not is_staging_test_clerk_email("load-sim-u01+clerk_test@example.com")
    assert not is_staging_test_clerk_email("load-sim-u20+clerk_test@example.com")


def test_staging_matcher_never_matches_real_domains():
    assert not is_staging_test_clerk_email("todd@engram.page")
    assert not is_staging_test_clerk_email("todd+clerk_test@engram.page")
    assert not is_staging_test_clerk_email("someone+clerk_test@gmail.com")
    assert not is_staging_test_clerk_email("someone@example.com")  # tag required
    assert not is_staging_test_clerk_email("x+clerk_test@example.com.evil.io")
    assert not is_staging_test_clerk_email("")


def test_ci_rule_unchanged():
    assert is_e2e_clerk_email("e2e-sync-1+clerk_test@example.com")
    assert is_e2e_clerk_email("e2e-browser-1@test.com")
    assert not is_e2e_clerk_email("tabtest+clerk_test@example.com")
    assert reaper.is_target_user(_user("tabtest+clerk_test@example.com"), "ci") is False
    assert reaper.is_target_user(_user("e2e-a+clerk_test@example.com"), "ci") is True


def test_staging_user_with_any_real_email_is_kept():
    u = _user("tabtest+clerk_test@example.com", "todd@engram.page")
    assert reaper.is_target_user(u, "staging") is False
    assert reaper.is_target_user(_user(), "staging") is False  # no emails at all


def test_staging_target_matches_tagged_user():
    assert reaper.is_target_user(_user("qc-flows+clerk_test@example.com"), "staging") is True


# ── age gate ─────────────────────────────────────────────────────────────


def test_staging_old_and_idle_is_reaped():
    u = _user("t+clerk_test@example.com", created=timedelta(days=30), active=timedelta(days=10))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is True


def test_staging_old_but_recently_active_is_kept():
    u = _user("t+clerk_test@example.com", created=timedelta(days=30), active=timedelta(days=1))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is False


def test_staging_falls_back_to_last_sign_in():
    u = _user("t+clerk_test@example.com", created=timedelta(days=30), sign_in=timedelta(hours=2))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is False
    u = _user("t+clerk_test@example.com", created=timedelta(days=30), sign_in=timedelta(days=9))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is True


def test_staging_recently_created_is_kept():
    u = _user("t+clerk_test@example.com", created=timedelta(days=2))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is False


def test_staging_never_signed_in_uses_created_at():
    u = _user("t+clerk_test@example.com", created=timedelta(days=30))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is True


def test_unknown_created_at_is_kept():
    u = _user("t+clerk_test@example.com")
    u["created_at"] = None
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is False
    assert reaper.is_old_enough(u, NOW, WEEK, "ci") is False


def test_ci_age_gate_ignores_activity():
    # CI keeps its existing created_at-only gate.
    u = _user("e2e-a+clerk_test@example.com", created=timedelta(hours=2), active=timedelta(seconds=1))
    assert reaper.is_old_enough(u, NOW, timedelta(hours=1), "ci") is True


def test_targets_read_separate_secret_env_vars():
    assert reaper.SECRET_ENV == {"ci": "E2E_CLERK_SECRET_KEY", "staging": "STAGING_CLERK_SECRET_KEY"}
