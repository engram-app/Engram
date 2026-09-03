"""The harness may not reach for a plugin symbol the surface check doesn't assert.

Stack-free. Guards the #1503 class at its root.

A CDP helper that names a plugin symbol which has since been renamed does not
fail — it silently does nothing, and every test built on it goes green while
proving nothing. `conftest.REQUIRED_ENGINE_METHODS` / `_PROPS` fix that by
asserting the surface once per session, but only for symbols someone remembered
to add. A helper reaching for a symbol *absent from those lists* is back to the
original failure mode.

So: scan the harness for `syncEngine` member accesses and require every one to
be declared. The lists stay honest without anyone remembering to update them,
because forgetting turns this red.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

_E2E = Path(__file__).resolve().parents[1]
_HARNESS = [_E2E / "helpers" / "cdp.py", _E2E / "conftest.py"]

# `{ENGINE_PATH}.foo`, `se.foo` (the local alias inside evaluated JS), and
# `syncEngine.foo` / `syncEngine?.foo`.
_ACCESS = re.compile(
    r"(?:\{ENGINE_PATH\}|\bse|\bsyncEngine\??)\.([A-Za-z_]\w*)",
)

# Names that are not plugin surface:
#   __*      test-injected bookkeeping the harness itself installs
#   _orig*   saved originals from a wrap/restore pair
_HARNESS_OWNED = re.compile(r"^(__|_orig)")

# Asserted by conftest under a STRONGER predicate than mere presence, so
# re-declaring them in the lists would only double-check them weakly.
_CHECKED_ELSEWHERE = {
    "syncState",  # asserted `instanceof Map`, not just defined
}


def _strip_comments(text: str) -> str:
    """Drop whole comment lines, Python and JS alike.

    Both this repo's incident write-ups and the conftest check itself NAME the
    symbols in prose (`syncEngine.recentlyPushed` appears in a comment
    explaining why it was removed). Scanning raw text reports those as live
    reaches, which would make this test fail on documentation.

    Whole lines only, deliberately: parsing `//` inside a string would have to
    understand `http://`, and a trailing comment after real code still leaves
    that code scanned, which is the correct outcome.
    """
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith("//"):
            continue
        out.append(line)
    return "\n".join(out)


def _load_conftest():
    sys.path.insert(0, str(_E2E))
    try:
        spec = importlib.util.spec_from_file_location("_e2e_conftest", _E2E / "conftest.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


@pytest.fixture(scope="module")
def declared() -> set[str]:
    c = _load_conftest()
    return set(c.REQUIRED_ENGINE_METHODS) | set(c.REQUIRED_ENGINE_PROPS)


def _reached() -> set[str]:
    found: set[str] = set()
    for path in _HARNESS:
        for name in _ACCESS.findall(_strip_comments(path.read_text())):
            if _HARNESS_OWNED.match(name) or name in _CHECKED_ELSEWHERE:
                continue
            found.add(name)
    return found


def test_every_reached_symbol_is_declared(declared):
    """A helper reaching for an undeclared symbol is the original bug, again."""
    undeclared = sorted(_reached() - declared)

    assert not undeclared, (
        f"the harness reaches for syncEngine members the session-start surface "
        f"check does not assert: {undeclared}. A rename of any of these fails "
        f"silently and takes its tests green with it — which is exactly how "
        f"four fan-out tests ran against a dead feature (#1503). Add them to "
        f"REQUIRED_ENGINE_METHODS or REQUIRED_ENGINE_PROPS in e2e/conftest.py, "
        f"or to _CHECKED_ELSEWHERE here with a reason."
    )


def test_the_scanner_actually_finds_things(declared):
    """Guard the guard: a regex that matched nothing would make this file inert.

    Without this, breaking `_ACCESS` turns the check above into a permanent
    green that asserts `set() - declared == []` — the same false-green shape
    the whole contract exists to prevent.
    """
    reached = _reached()

    assert len(reached) > 20, (
        f"the harness scanner found only {len(reached)} syncEngine members "
        f"({sorted(reached)}). It found 30 when written, so the regex has "
        f"almost certainly stopped matching — this file is now inert."
    )
    # Anchor on a symbol the harness has reached for since the fan-out rework.
    assert "applyPushedNoteUpdate" in reached


def test_declared_lists_are_disjoint(declared):
    """A name in both lists gets checked as a function AND a property."""
    c = _load_conftest()
    overlap = set(c.REQUIRED_ENGINE_METHODS) & set(c.REQUIRED_ENGINE_PROPS)

    assert not overlap, f"declared as both method and property: {sorted(overlap)}"
