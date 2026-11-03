"""Staging Clerk test-user reaper: matcher + age gate.

Staging's Clerk instance (`key-longhorn-79`, also local saas-dev) had no
sweep, so ad-hoc agent/QA accounts (`<anything>+clerk_test@example.com`)
piled up. The reaper's `--target staging` mode owns those, except the
`load-sim-uNN` accounts that e2e/load/sim.py reuses across runs, and only
once BOTH creation and last activity are older than `--older-than`.
"""

import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from helpers.clerk_constants import (
    LOAD_SIM_PREFIX,
    is_e2e_clerk_email,
    is_staging_test_clerk_email,
)

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


def test_staging_activity_uses_most_recent_timestamp():
    # last_active_at present but older than a fresh sign-in: the sign-in wins.
    u = _user("t+clerk_test@example.com", created=timedelta(days=30),
              active=timedelta(days=20), sign_in=timedelta(hours=3))
    assert reaper.is_old_enough(u, NOW, WEEK, "staging") is False


@pytest.mark.parametrize("field", ["phone_numbers", "external_accounts", "web3_wallets",
                                   "enterprise_accounts"])
def test_staging_user_with_other_identifiers_is_kept(field):
    u = _user("tabtest+clerk_test@example.com")
    u[field] = [{"id": "x"}]
    assert reaper.is_target_user(u, "staging") is False


def test_sim_default_prefix_is_the_kept_prefix():
    from load import sim

    assert sim.LOAD_SIM_PREFIX == LOAD_SIM_PREFIX
    assert not is_staging_test_clerk_email(f"{LOAD_SIM_PREFIX}-u01+clerk_test@example.com")


# ── main() end to end, HTTP mocked ───────────────────────────────────────

REAL_NOW = datetime.now(timezone.utc)
OLD = int((REAL_NOW - timedelta(days=30)).timestamp() * 1000)


def _stale(email, uid):
    return {"id": uid, "email_addresses": [{"email_address": email}],
            "created_at": OLD, "last_active_at": OLD, "last_sign_in_at": None}


class _Resp:
    def __init__(self, status=200, body=None):
        self.status_code, self._body = status, body
        self.ok, self.text = status < 400, ""

    def json(self):
        return self._body

    def raise_for_status(self):
        assert self.ok


class _FakeSession:
    def __init__(self, users, delete_status=200):
        self.users, self.delete_status = users, delete_status
        self.headers, self.gets, self.deletes = {}, 0, []

    def get(self, url, params=None, timeout=None):
        self.gets += 1
        return _Resp(body=self.users if params["offset"] == 0 else [])

    def delete(self, url, timeout=None):
        self.deletes.append(url.rsplit("/", 1)[1])
        return _Resp(self.delete_status)


@pytest.fixture
def run(monkeypatch):
    def _run(argv, users=(), env=None, delete_status=200):
        sess = _FakeSession(list(users), delete_status)
        monkeypatch.setattr(reaper.requests, "Session", lambda: sess)
        monkeypatch.setattr(reaper.time, "sleep", lambda _s: None)
        for k in reaper.SECRET_ENV.values():
            monkeypatch.delenv(k, raising=False)
        for k, v in (env or {}).items():
            monkeypatch.setenv(k, v)
        monkeypatch.setattr(sys, "argv", ["cleanup_clerk_users.py", *argv])
        code = 0
        try:
            reaper.main()
        except SystemExit as e:
            code = e.code
        return code, sess
    return _run


STAGING = ["--target", "staging", "--older-than", "7d"]
STG_KEY = {"STAGING_CLERK_SECRET_KEY": "sk_test_stg"}
USERS = [
    _stale("tabtest+clerk_test@example.com", "u1"),
    _stale("load-sim-u01+clerk_test@example.com", "u2"),
    _stale("todd@engram.page", "u3"),
    _stale("qc-flows+clerk_test@example.com", "u4"),
]


def test_main_staging_deletes_only_tagged_users(run):
    code, sess = run(STAGING, USERS, STG_KEY)
    assert code == 0 and sess.deletes == ["u1", "u4"]


def test_main_staging_dry_run_issues_no_delete(run):
    code, sess = run([*STAGING, "--dry-run"], USERS, STG_KEY)
    assert code == 0 and sess.gets >= 1 and sess.deletes == []


def test_main_staging_ignores_the_ci_key(run):
    code, sess = run(STAGING, USERS, {"E2E_CLERK_SECRET_KEY": "sk_test_ci"})
    assert code == 1 and sess.gets == 0 and sess.deletes == []


def test_main_staging_requires_older_than(run):
    code, sess = run(["--target", "staging"], USERS, STG_KEY)
    assert code == 2 and sess.gets == 0


@pytest.mark.parametrize("window", ["0s", "12h", "23h"])
def test_main_staging_rejects_window_below_one_day(run, window):
    code, sess = run(["--target", "staging", "--older-than", window], USERS, STG_KEY)
    assert code == 2 and sess.gets == 0


def test_main_staging_refuses_live_key(run):
    code, sess = run(STAGING, USERS, {"STAGING_CLERK_SECRET_KEY": "sk_live_prod"})
    assert code == 1 and sess.gets == 0 and sess.deletes == []


def test_main_refuses_over_cap_before_any_delete(run):
    code, sess = run([*STAGING, "--max-deletes", "1"], USERS, STG_KEY)
    assert code == 1 and sess.deletes == []


def test_main_staging_default_cap_is_40(run):
    many = [_stale(f"t{i}+clerk_test@example.com", f"u{i}") for i in range(41)]
    code, sess = run(STAGING, many, STG_KEY)
    assert code == 1 and sess.deletes == []
    code, sess = run(STAGING, many[:40], STG_KEY)
    assert code == 0 and len(sess.deletes) == 40


def test_main_failed_delete_exits_nonzero_after_trying_all(run):
    code, sess = run(STAGING, USERS, STG_KEY, delete_status=500)
    assert code == 1 and sess.deletes == ["u1", "u4"]


def test_main_ci_target_unchanged(run):
    users = [_stale("e2e-a+clerk_test@example.com", "c1"), *USERS]
    code, sess = run(["--older-than", "1h"], users, {"E2E_CLERK_SECRET_KEY": "sk_test_ci"})
    assert code == 0 and sess.deletes == ["c1"]
