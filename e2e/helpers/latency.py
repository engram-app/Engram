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
# asserts cross-vault labelling, not latency. 120s matches the server's own
# ceiling for the same work (`Engram.Embedders.Ollama` request_defaults →
# `receive_timeout: 120_000`), so the client now gives up only when the server
# would have. This is a true-breakage bound, NOT a performance budget — real
# search latency is watched by `engram_prom_ex_search_request_duration_*`.
SEARCH_TIMEOUT = float(os.environ.get("E2E_SEARCH_TIMEOUT", "120"))
