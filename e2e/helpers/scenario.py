"""Timed steps for canary scenarios.

`timed_step(name)` appends `{"step", "seconds", "ok"}` to the active step list,
which the `scenario_steps` fixture (e2e/conftest.py) binds to the node's
`user_properties["steps"]` so the timings land in the junit XML properties.
"""

from __future__ import annotations

import json
import os
import time
from contextlib import contextmanager
from pathlib import Path

# ponytail: one global, the suite is serial; per-task contextvar if tests ever run concurrently.
_active: list | None = None


def bind_steps(user_properties: list) -> list:
    """Make `user_properties["steps"]` the active list (created once) and return it."""
    global _active
    steps = next((v for k, v in user_properties if k == "steps"), None)
    if steps is None:
        steps = []
        user_properties.append(("steps", steps))
    _active = steps
    return steps


def unbind_steps() -> None:
    global _active
    _active = None


@contextmanager
def timed_step(name: str):
    if _active is None:
        raise RuntimeError("timed_step needs the scenario_steps fixture")
    start = time.monotonic()
    ok = False
    try:
        yield
        ok = True
    finally:
        _active.append({"step": name, "seconds": time.monotonic() - start, "ok": ok})


def pytest_collection_modifyitems(items):
    """Write canary marker args for scripts/list_scenarios.py.

    Only active when SCENARIO_COLLECT_OUT names a path; a normal run is untouched.
    Accepts `canary("hourly", ["ci"])` and `canary(cadence=..., targets=...)`.
    """
    out = os.environ.get("SCENARIO_COLLECT_OUT")
    if not out:
        return
    entries = []
    for item in items:
        marker = item.get_closest_marker("canary")
        if marker is not None:
            bound = dict(zip(("cadence", "targets"), marker.args)) | marker.kwargs
            entries.append({"nodeid": item.nodeid, **bound})
    Path(out).write_text(json.dumps(entries))
