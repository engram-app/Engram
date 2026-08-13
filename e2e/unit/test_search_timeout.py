"""Search-bearing HTTP calls must use SEARCH_TIMEOUT, never a hardcoded one.

Regression guard for the 2026-08-12 class: `mcp_call` carried `timeout=10` and
`search` carried `timeout=15` — unexamined copy-paste defaults, never a latency
SLO. A search's cost is dominated by one query embed, which in CI queues behind
the embed worker's 128-chunk index batches on the shared FastRaid Ollama
(serialized: ~4.3s of wait per in-flight batch, measured). At three batches deep
the 10s expired and `test_32::test_mcp_search_spans_all_vaults_by_default` died
with a ReadTimeout having evaluated no assertion at all.

Re-hardcoding a number on either call site brings the flake straight back, and
it looks entirely innocent in review — hence this guard. See
`docs/context/e2e-clerk-failure-taxonomy.md`.
"""

import inspect
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from helpers.api import ApiClient  # noqa: E402
from helpers.latency import SEARCH_TIMEOUT  # noqa: E402

# Both pay the same query-embed cost: MCP `tools/call` and REST `POST /search`.
SEARCH_BEARING = [ApiClient.mcp_call, ApiClient.search]


def test_search_calls_use_the_named_budget():
    for method in SEARCH_BEARING:
        assert "timeout=SEARCH_TIMEOUT" in inspect.getsource(method), (
            f"{method.__qualname__} must pass timeout=SEARCH_TIMEOUT"
        )


def test_search_calls_carry_no_hardcoded_timeout():
    for method in SEARCH_BEARING:
        literals = re.findall(r"timeout=(\d+)", inspect.getsource(method))
        assert not literals, (
            f"{method.__qualname__} hardcodes timeout={literals} — use "
            "SEARCH_TIMEOUT so the budget stays one documented number"
        )


def test_budget_exceeds_measured_queueing():
    # 3 in-flight index batches measured ~13.1s; the old 10s sat under that.
    # The default also matches the server's own ceiling for the same work
    # (Embedders.Ollama receive_timeout: 120_000), so the client gives up only
    # when the server would have.
    assert SEARCH_TIMEOUT >= 60, (
        f"SEARCH_TIMEOUT={SEARCH_TIMEOUT} is back in the range that expires on "
        "queue depth rather than on breakage"
    )


def test_budget_is_env_overridable():
    import importlib

    import helpers.latency

    os.environ["E2E_SEARCH_TIMEOUT"] = "7"
    try:
        assert importlib.reload(helpers.latency).SEARCH_TIMEOUT == 7.0
    finally:
        del os.environ["E2E_SEARCH_TIMEOUT"]
        importlib.reload(helpers.latency)
