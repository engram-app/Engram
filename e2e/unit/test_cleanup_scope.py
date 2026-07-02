"""Unit tests for the run/job-scoped Clerk sweep — no CI stack needed.

Regression lock for the second (and dominant) #869 failure mode: the
worker-0 `auth_provider` setup sweep was scoped by GITHUB_RUN_ID only, but
all parallel jobs of one workflow run SHARE that run id — so the e2e-api
job's setup sweep deleted the e2e-clerk job's live users mid-suite
(observed 2026-07-02: every e2e-clerk user 404'd at teardown; only test_49
noticed because it is the only mid-suite Clerk session minter). The sweep
must be scoped to run AND job.
"""

from __future__ import annotations

from helpers.cleanup import cleanup_all_e2e_clerk_users


class _FakeClerkClient:
    def __init__(self, users: list[dict]) -> None:
        self._users = users
        self.deleted: list[str] = []

    def list_users(self, limit: int = 100, offset: int = 0) -> list[dict]:
        return self._users[offset : offset + limit]

    def delete_user(self, user_id: str) -> None:
        self.deleted.append(user_id)


def _user(uid: str, email: str) -> dict:
    return {"id": uid, "email_addresses": [{"email_address": email}]}


def test_sweep_scoped_to_run_and_job() -> None:
    client = _FakeClerkClient(
        [
            # Same run, SAME job (a previous attempt's leftover) — delete.
            _user("u_own", "e2e-sync-123r777je2e-clerkw0+clerk_test@example.com"),
            # Same run, DIFFERENT job (live sibling job's user) — keep!
            _user("u_sibling", "e2e-sync-124r777je2e-apiw0+clerk_test@example.com"),
            # Different run — keep.
            _user("u_other_run", "e2e-sync-125r888je2e-clerkw0+clerk_test@example.com"),
            # Not an e2e user — keep.
            _user("u_real", "todd@example.com"),
        ]
    )

    deleted = cleanup_all_e2e_clerk_users(client, run_id="777", job_id="e2e-clerk")

    assert client.deleted == ["u_own"]
    assert deleted == 1


def test_sweep_without_job_scope_keeps_legacy_run_marker() -> None:
    """run_id without job_id keeps the old r{run}w anchor (legacy emails)."""
    client = _FakeClerkClient(
        [
            _user("u_legacy", "e2e-sync-123r777w0+clerk_test@example.com"),
            _user("u_other", "e2e-sync-124r888w0+clerk_test@example.com"),
        ]
    )

    deleted = cleanup_all_e2e_clerk_users(client, run_id="777")

    assert client.deleted == ["u_legacy"]
    assert deleted == 1


def test_nuclear_sweep_still_deletes_all_e2e_users() -> None:
    """run_id=None (standalone reaper path) deletes every e2e user."""
    client = _FakeClerkClient(
        [
            _user("u_a", "e2e-sync-123r777je2e-clerkw0+clerk_test@example.com"),
            _user("u_b", "e2e-iso-124r888je2e-apiw1+clerk_test@example.com"),
            _user("u_real", "todd@example.com"),
        ]
    )

    deleted = cleanup_all_e2e_clerk_users(client, run_id=None)

    assert client.deleted == ["u_a", "u_b"]
    assert deleted == 2
