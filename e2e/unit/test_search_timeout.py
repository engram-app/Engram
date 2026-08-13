"""Search-bearing HTTP calls must use SEARCH_TIMEOUT, never a hardcoded one.

Regression guard for the 2026-08-12 class: `mcp_call` carried `timeout=10` and
`search` carried `timeout=15` — unexamined copy-paste defaults, never a latency
SLO. A search's cost is dominated by one query embed, which in CI queues behind
the embed worker's 128-chunk index batches on the shared FastRaid Ollama
(serialized: ~4.3s of wait per in-flight batch, measured). At three batches deep
the 10s expired and `test_32::test_mcp_search_spans_all_vaults_by_default` died
with a ReadTimeout having evaluated no assertion at all.

Two ways to reintroduce it, both of which look innocent in review, so both are
guarded here:
  1. re-hardcoding a number on a helper call site;
  2. hand-rolling `client.session.post(f"{API_URL}/search", ...)` in a test,
     which silently opts out of the budget entirely. That is how
     `test_67`/`test_77` kept `timeout=30` while `ApiClient.search` sat unused.

See `docs/context/e2e-clerk-failure-taxonomy.md`.
"""

import inspect
import re
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.latency import SEARCH_TIMEOUT

# Both pay the same query-embed cost: MCP `tools/call` and REST `POST /search`.
SEARCH_BEARING = [ApiClient.mcp_call, ApiClient.search]

TESTS_DIR = Path(__file__).resolve().parent.parent / "tests"


def test_search_calls_use_the_named_budget():
    for method in SEARCH_BEARING:
        assert "SEARCH_TIMEOUT" in inspect.getsource(method), (
            f"{method.__qualname__} must pass timeout=SEARCH_TIMEOUT"
        )


def test_search_calls_carry_no_hardcoded_timeout():
    for method in SEARCH_BEARING:
        literals = re.findall(r"timeout=(\d+)", inspect.getsource(method))
        assert not literals, (
            f"{method.__qualname__} hardcodes timeout={literals} — use "
            "SEARCH_TIMEOUT so the budget stays one documented number"
        )


def test_no_test_hand_rolls_a_search_post():
    """A /search POST outside ApiClient.search bypasses the budget entirely."""
    offenders = []
    for path in TESTS_DIR.rglob("*.py"):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if "/search" in line and ".post(" in line:
                offenders.append(f"{path.relative_to(TESTS_DIR.parent)}:{n}")
    assert not offenders, (
        "these call POST /search directly instead of ApiClient.search, so they "
        f"opt out of SEARCH_TIMEOUT: {offenders}"
    )


def test_budget_default_exceeds_measured_queueing():
    """Asserts the DEFAULT, not the runtime value.

    Reading the runtime value here would red this guard for anyone using the
    documented `E2E_SEARCH_TIMEOUT` override to keep a local run snappy — and
    would contradict test_budget_is_env_overridable four lines down.
    """
    src = (Path(__file__).resolve().parent.parent / "helpers" / "latency.py").read_text()
    default = float(re.search(r'E2E_SEARCH_TIMEOUT",\s*"(\d+)"', src).group(1))
    # 3 in-flight index batches measured ~13.1s; the old 10s sat under that. The
    # default also stays well above the server's own query-embed ceiling
    # (Embedders.Ollama request_defaults(:query) → 45s) so the client is never
    # the first to give up.
    assert default >= 60, (
        f"default SEARCH_TIMEOUT={default} is back in the range that expires on "
        "queue depth rather than on breakage"
    )


def test_budget_is_env_overridable(monkeypatch):
    """monkeypatch, not del os.environ — the latter destroys a pre-existing
    value instead of restoring it, leaving helpers.latency and the already
    imported helpers.api disagreeing for the rest of the process."""
    import importlib

    import helpers.latency

    monkeypatch.setenv("E2E_SEARCH_TIMEOUT", "7")
    try:
        assert importlib.reload(helpers.latency).SEARCH_TIMEOUT == 7.0
    finally:
        monkeypatch.delenv("E2E_SEARCH_TIMEOUT", raising=False)
        importlib.reload(helpers.latency)


def test_reload_restored_the_module():
    """Sanity: the reload above must leave the real budget in place."""
    import helpers.latency

    assert helpers.latency.SEARCH_TIMEOUT == SEARCH_TIMEOUT


@pytest.mark.parametrize("tool,expects_search_budget", [("search_notes", True), ("get_note", False)])
def test_only_embedding_tools_get_the_search_budget(tool, expects_search_budget):
    assert (tool in ApiClient._EMBEDDING_MCP_TOOLS) is expects_search_budget
