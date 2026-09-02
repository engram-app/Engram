"""Unit tests for the infra circuit breaker's exit reporting — no CI stack needed.

Regression lock for the cascade class: when an Obsidian/CDP instance dies
mid-suite, the tests that already failed are recorded as ordinary failures and
the run exits 1 — indistinguishable in CI from real product breakage. Two such
runs on 2026-09-01/02 produced 20 red entries across the frontmatter,
index-crdt and live-bound suites, and every one of them was downstream of the
dead instance rather than a broken feature.

The breaker must therefore report distinctly: a dedicated exit code so the run
says "infra", not "20 features are broken". It must NOT go green — a dead stack
proved nothing — and it must stay silent on a normal run.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_CONFTEST = Path(__file__).resolve().parents[1] / "conftest.py"


def _load_conftest():
    """Import e2e/conftest.py as a module without pytest collecting it.

    e2e/unit has its own rootdir, so the parent conftest is not otherwise
    importable here. Its import-time body only reads env vars.
    """
    sys.path.insert(0, str(_CONFTEST.parent))
    try:
        spec = importlib.util.spec_from_file_location("_e2e_conftest", _CONFTEST)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


class _FakeSession:
    def __init__(self, exitstatus: int = 1) -> None:
        self.exitstatus = exitstatus


@pytest.fixture
def conftest():
    module = _load_conftest()
    module._infra_dead_reason = None
    return module


def test_normal_run_exit_status_is_untouched(conftest):
    """No infra death: the hook must not rewrite a real pass or a real failure."""
    for original in (0, 1):
        session = _FakeSession(original)
        conftest.pytest_sessionfinish(session, original)
        assert session.exitstatus == original, (
            "the breaker rewrote the exit status of a run it never tripped on — "
            "real test failures would be reported as infra deaths"
        )


def test_infra_death_gets_its_own_exit_code(conftest, capsys):
    """Breaker tripped: distinct exit code, and an annotation naming the cause."""
    conftest._infra_dead_reason = "INFRA DEAD: an Obsidian/CDP instance is gone (last: test_x)."

    session = _FakeSession(1)
    conftest.pytest_sessionfinish(session, 1)

    assert session.exitstatus == conftest.INFRA_DEAD_EXIT_CODE
    out = capsys.readouterr().out
    assert "::error title=E2E infra died::" in out, (
        "no workflow annotation — the run still reads as N broken features in the UI"
    )
    assert "an Obsidian/CDP instance is gone" in out, "annotation dropped the cause"


def test_infra_death_never_reports_success(conftest):
    """A dead stack proved nothing. It must not exit 0 under any circumstance."""
    conftest._infra_dead_reason = "INFRA DEAD: backend refuses connections."

    # Worst case: the breaker trips on the very last test and pytest was
    # otherwise about to report a clean pass.
    session = _FakeSession(0)
    conftest.pytest_sessionfinish(session, 0)

    assert session.exitstatus != 0, "an infra death reported as a green run"
    assert session.exitstatus == conftest.INFRA_DEAD_EXIT_CODE
