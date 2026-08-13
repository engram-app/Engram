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
     `test_50`/`test_67`/`test_77` kept `timeout=30` while `ApiClient.search`
     sat unused with ZERO callers.

The guard for (2) must scan file TEXT, not line by line: the real offenders
split the call across lines, so a per-line `"/search" in line and ".post(" in
line` check matched none of them while reporting green.

See `docs/context/e2e-clerk-failure-taxonomy.md`.
"""

import inspect
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.latency import SEARCH_TIMEOUT

# Both pay the same query-embed cost: MCP `tools/call` and REST `POST /search`.
SEARCH_BEARING = [ApiClient.mcp_call, ApiClient.search]

E2E_DIR = Path(__file__).resolve().parent.parent
TESTS_DIR = E2E_DIR / "tests"

# `.post(` … `/search`, across newlines. Deliberately not per-line.
_HANDROLLED_SEARCH = re.compile(r"\.post\(\s*\n?\s*f?\"[^\"]*?/search", re.MULTILINE)


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
    offenders = [
        str(p.relative_to(E2E_DIR))
        for p in TESTS_DIR.rglob("*.py")
        if _HANDROLLED_SEARCH.search(p.read_text())
    ]
    assert not offenders, (
        "these call POST /search directly instead of ApiClient.search, so they "
        f"opt out of SEARCH_TIMEOUT: {offenders}"
    )


def test_the_handrolled_guard_actually_matches_a_multiline_call():
    """The guard this file relies on must catch the shape the offenders used.

    The first version of it only matched single-line calls and so reported green
    against three live offenders. Pin the multi-line shape explicitly.
    """
    multiline = 'resp = client.session.post(\n    f"{API_URL}/search", json=body, timeout=30\n)'
    assert _HANDROLLED_SEARCH.search(multiline)
    single = 'resp = self.session.post(f"{self.base_url}/search", json=body, timeout=30)'
    assert _HANDROLLED_SEARCH.search(single)


def _module_default() -> float:
    src = (E2E_DIR / "helpers" / "latency.py").read_text()
    return float(re.search(r'E2E_SEARCH_TIMEOUT",\s*"(\d+)"', src).group(1))


def test_budget_default_exceeds_measured_queueing():
    """Asserts the DEFAULT, not the runtime value.

    Reading the runtime value would red this guard for anyone using the
    documented `E2E_SEARCH_TIMEOUT` override to keep a local run snappy — and
    would contradict test_budget_is_env_overridable below.
    """
    # 3 in-flight index batches measured ~13.1s; the old 10s sat under that.
    assert _module_default() >= 60


# Budget for the rest of a search request after the embed: sparse leg (Qdrant
# :search 5s), candidate decryption, rerank, MMR. The client must clear the
# WHOLE request, not just the embed.
POST_EMBED_ALLOWANCE_S = 10


def _ollama_query_ceiling_s() -> float:
    """Read the server-side :query budget from the Elixir source.

    Deliberately NOT hardcoded. A literal here would keep passing if
    Ollama.query_defaults/0 were later raised past SEARCH_TIMEOUT — the guard
    would go green on exactly the regression it exists to catch, which is the
    same "guard that cannot fail" class this file's docstring calls out.
    """
    src = (E2E_DIR.parent / "lib" / "engram" / "embedders" / "ollama.ex").read_text()
    body = re.search(r"defp query_defaults,?\s*do:\s*\[(.*?)\]", src, re.S).group(1)
    ms = float(re.search(r"receive_timeout:\s*([\d_]+)", body).group(1).replace("_", ""))
    # `retry: false` keeps this flat; with retries it would be ~4x + backoff.
    assert "retry: false" in body, (
        "Ollama :query re-enabled retries — the ceiling is no longer flat and "
        "this nesting calculation is invalid (a late reset costs ~4x the budget)"
    )
    return ms / 1000


def test_budget_nests_between_server_ceiling_and_caller_deadlines():
    """The budget is useless if it can never fire.

    Must exceed the server's WHOLE-request ceiling so the client is never first
    to give up, but stay under the 90s poll windows in test_67/test_77 and the
    180s pytest-timeout — otherwise a slow search is reported as "never landed"
    or killed by SIGALRM.
    """
    default = _module_default()
    server_ceiling = _ollama_query_ceiling_s() + POST_EMBED_ALLOWANCE_S
    assert default > server_ceiling, (
        f"{default}s does not clear the server's whole-request ceiling of "
        f"{server_ceiling}s (embed {_ollama_query_ceiling_s()}s + "
        f"{POST_EMBED_ALLOWANCE_S}s for the sparse leg, decrypt, rerank, MMR)"
    )
    assert default < 90, f"{default}s exceeds the 90s caller poll windows"

    pytest_ini = (E2E_DIR / "pytest.ini").read_text()
    per_test = float(re.search(r"^timeout\s*=\s*(\d+)", pytest_ini, re.MULTILINE).group(1))
    assert default < per_test, f"{default}s exceeds the pytest-timeout of {per_test}s"


def test_non_search_mcp_calls_fit_inside_one_test():
    """MCP tools that don't embed must not use a polling-loop budget.

    test_46 makes five mcp_calls; at DELIVERY_TIMEOUT (120s) two wedged calls
    already exceed the pytest-timeout, so the suite dies with SIGALRM instead of
    a clean ReadTimeout.
    """
    from helpers.latency import MCP_TIMEOUT

    pytest_ini = (E2E_DIR / "pytest.ini").read_text()
    per_test = float(re.search(r"^timeout\s*=\s*(\d+)", pytest_ini, re.MULTILINE).group(1))
    assert MCP_TIMEOUT * 5 <= per_test, (
        f"five wedged MCP calls ({MCP_TIMEOUT}s each) exceed the {per_test}s "
        "pytest-timeout — failures will surface as SIGALRM, not ReadTimeout"
    )


def test_budget_is_env_overridable():
    """Runs in a subprocess.

    Doing this in-process means mutating os.environ and reloading the module,
    which cannot be undone cleanly: monkeypatch restores the env only AFTER the
    test returns, so any reload in a finally: block re-reads the patched value
    and leaves helpers.latency disagreeing with the already-imported
    helpers.api for the rest of the session. A subprocess has neither problem.
    """
    out = subprocess.run(
        [sys.executable, "-c", "from helpers.latency import SEARCH_TIMEOUT; print(SEARCH_TIMEOUT)"],
        cwd=E2E_DIR,
        env={**os.environ, "E2E_SEARCH_TIMEOUT": "7", "PYTHONPATH": str(E2E_DIR)},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert out.returncode == 0, out.stderr
    assert float(out.stdout.strip()) == 7.0


def test_this_process_still_sees_the_real_budget():
    """Sanity: nothing above may have mutated the live budget."""
    import helpers.latency

    assert helpers.latency.SEARCH_TIMEOUT == SEARCH_TIMEOUT == _module_default()


@pytest.mark.parametrize(
    "tool,embeds",
    [
        ("search_notes", True),
        ("suggest_folder", True),
        ("create_note", True),
        ("get_note", False),
        ("write_note", False),
    ],
)
def test_only_embedding_tools_get_the_search_budget(tool, embeds):
    """Verified against lib/engram/mcp/handlers.ex — suggest_folder and
    create_note reach Engram.Search too, which the first cut of this list
    missed."""
    assert (tool in ApiClient._EMBEDDING_MCP_TOOLS) is embeds
