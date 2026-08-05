"""Unit tests for the MinIO teardown bucket guard — no CI stack needed.

Regression lock for the blast radius created on 2026-08-05, when attachment
storage moved off a per-stack MinIO sidecar onto the central FastRaid MinIO
(ci/compose.yml) to stop the runner VMs filling their disks.

Before the move, `cleanup_minio_bucket()`'s recursive force-delete could only
ever destroy a throwaway container's data. After it, the same call runs against
a host that ALSO holds:

    engram-saas-attachments        staging's live attachments
    engram-selfhost-attachments    selfhost's live attachments

so a wrong `CI_MINIO_BUCKET` — a bad default, a stale workflow env, a copied
compose file — would silently wipe staging during ordinary test teardown.

The mitigation is a guard on the shared teardown path rather than care with
configuration: config can be wrong, and every caller routes through here.
"""

from __future__ import annotations

import pytest

from helpers import cleanup


@pytest.fixture(autouse=True)
def _no_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    """Strip creds so a bucket that PASSES the guard still can't reach the network."""
    monkeypatch.delenv("CI_MINIO_ACCESS_KEY", raising=False)
    monkeypatch.delenv("CI_MINIO_SECRET_KEY", raising=False)


@pytest.fixture
def _explode_on_subprocess(monkeypatch: pytest.MonkeyPatch) -> None:
    """Any subprocess call at all is a test failure — the guard must run first."""

    def _boom(*args: object, **kwargs: object) -> None:
        raise AssertionError(f"cleanup shelled out despite the guard: {args!r}")

    monkeypatch.setattr(cleanup.subprocess, "run", _boom)


@pytest.mark.parametrize(
    "bucket",
    [
        "engram-saas-attachments",  # staging — the one that actually matters
        "engram-selfhost-attachments",  # selfhost
        "engram-attachments",  # the pre-migration CI default, now dangerous
        "",  # unset env resolving to empty
        "ci",  # prefix without the separator
        "cinema",  # `ci` as a substring, not the namespace
        "not-ci-123",  # `ci-` present but not anchored
        "CI-123",  # uppercase — S3 buckets are lowercase; don't accept it
        "ci-123/../engram-saas-attachments",  # path traversal into a sibling
    ],
)
def test_guard_refuses_buckets_outside_ci_namespace(
    monkeypatch: pytest.MonkeyPatch, _explode_on_subprocess: None, bucket: str
) -> None:
    monkeypatch.setattr(cleanup, "CI_MINIO_BUCKET", bucket)

    with pytest.raises(ValueError, match="refusing to purge"):
        cleanup.cleanup_minio_bucket()


@pytest.mark.parametrize(
    "bucket",
    [
        "ci-local",
        "ci-12345678",
        "ci-12345678-obsidian",
        "ci-crdt-12345678",
    ],
)
def test_guard_allows_run_scoped_ci_buckets(
    monkeypatch: pytest.MonkeyPatch, bucket: str
) -> None:
    """Names the workflow actually generates must survive the guard.

    Reaching the credentials check (and returning quietly) proves the guard
    passed — the autouse fixture guarantees no network call follows.
    """
    monkeypatch.setattr(cleanup, "CI_MINIO_BUCKET", bucket)

    cleanup.cleanup_minio_bucket()  # must not raise


def test_purges_contents_but_never_removes_the_bucket(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Session teardown must use `mc rm`, NEVER `mc rb`.

    A single CI job runs more than one pytest session against ONE stack:
    e2e-clerk runs the API-only tier while Obsidian boots, then the Obsidian
    suite. `mc rb` at the end of the first session removed the bucket out from
    under the second, and every attachment write then died on NoSuchBucket —
    surfacing as 5 red sync tests whose logs never mentioned storage
    (run 31043944743).

    Reclaiming the bucket belongs to verify.yml's job-level teardown, which
    runs once, at the end, even on cancel.
    """
    monkeypatch.setattr(cleanup, "CI_MINIO_BUCKET", "ci-4242")
    monkeypatch.setenv("CI_MINIO_ACCESS_KEY", "ak")
    monkeypatch.setenv("CI_MINIO_SECRET_KEY", "sk")

    captured: dict[str, list[str]] = {}

    def _capture(cmd: list[str], **kwargs: object) -> object:
        captured["cmd"] = cmd
        return type("R", (), {"returncode": 0, "stderr": ""})()

    monkeypatch.setattr(cleanup.subprocess, "run", _capture)
    cleanup.cleanup_minio_bucket()

    shell_cmd = captured["cmd"][-1]
    assert "mc rm --recursive --force central/ci-4242/" in shell_cmd
    assert "mc rb" not in shell_cmd, "must not remove the bucket at session teardown"


def test_missing_credentials_is_a_quiet_skip_not_a_crash(
    monkeypatch: pytest.MonkeyPatch, _explode_on_subprocess: None
) -> None:
    """Teardown runs in contexts with no MinIO at all (unit tiers, local runs).

    A valid bucket with no creds must no-op rather than fail the suite in
    teardown, which would mask the real test result.
    """
    monkeypatch.setattr(cleanup, "CI_MINIO_BUCKET", "ci-999")

    cleanup.cleanup_minio_bucket()
