"""Central delivery budget (determinism decision, 2026-07-22).

Correctness asserts wait on the observable event (file/note materializing)
under ONE generous budget that only expires on true breakage. The old 8-30s
budgets were performance assertions wearing correctness costumes — the same
SHA passed and failed depending on runner load. This budget is a
true-breakage bound: convergence normally lands in well under a second; the
deadline only fires when delivery is genuinely broken. Override with
``E2E_DELIVERY_TIMEOUT`` (seconds).
"""

from __future__ import annotations

import os

DELIVERY_TIMEOUT = float(os.environ.get("E2E_DELIVERY_TIMEOUT", "120"))

# Same decision, applied to search-bearing HTTP calls (`POST /search`, MCP
# `tools/call`). These were 15s/10s — unexamined copy-paste defaults, not a
# latency SLO, and nothing documented them as one.
#
# A search's cost is dominated by ONE query embed, and in CI that embed queues
# behind the embed worker's bulk index batches on the shared FastRaid Ollama
# (`10.0.20.214:11434`), which serializes requests. Measured 2026-08-12 against
# that box with `mxbai-embed-large`:
#
#   idle query embed .................................. ~0.12s
#   one 128-chunk index batch (@embed_batch_size) ..... ~5.2s
#   query embed behind 1 in-flight batch .............. ~4.3s
#   query embed behind 2 in-flight batches ............ ~8.4s
#   query embed behind 3 in-flight batches ............ ~13.1s  ← blew the 10s
#
# So the old 10s expired on queue depth, not on breakage — load-correlated, and
# the test it failed (`test_32::test_mcp_search_spans_all_vaults_by_default`)
# asserts cross-vault labelling, not latency.
#
# The budget has to NEST inside the deadlines that already wrap these calls, or
# it can never actually fire and the failure surfaces as the wrong diagnosis:
#
#   server query-embed ceiling ..... ~52s  (Ollama :query 45s + ~7s Req backoff)
#   SEARCH_TIMEOUT (this) ..........  60s  ← must exceed the server, but…
#   caller poll windows ............  90s  (test_77 `_poll_search`, test_67)
#   pytest-timeout per test ........ 180s  (e2e/pytest.ini)
#
# Above the server so the CLIENT is never the first to give up — otherwise a
# server-side failure reaches us as an ambiguous ReadTimeout instead of the real
# response the server was about to send. Below the poll windows so a genuinely
# slow search reports as a slow search, rather than eating a whole 90s poll loop
# and getting reported as "the repath never landed" (a wrong diagnosis) or being
# killed by pytest-timeout with a SIGALRM traceback.
#
# 120s was the first cut and did not nest: it exceeded every window above it, so
# it was unreachable in the tests that use it.
#
# This is a true-breakage bound, NOT a performance budget — real search latency
# is watched by `engram_prom_ex_search_request_duration_*`.
SEARCH_TIMEOUT = float(os.environ.get("E2E_SEARCH_TIMEOUT", "60"))
