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
