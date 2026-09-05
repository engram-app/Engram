"""Test 52: SearchModal UI coverage.

Covers the ``Semantic search`` command opening SearchModal and the empty-state
hint rendered when the query field is blank.

The indexed-note round-trip variant (write → sync → poll /search → assert
result) was removed: it depends on the Ollama embedding pipeline indexing a
note within a bounded CI window, which is fundamentally non-deterministic
(third-party process timing, not plugin behaviour).  Search-result rendering
is exercised by the deterministic API-level test in ``test_search.py`` /
``tests/search.test.ts`` (unit) — there is no value in a flaky e2e duplicate.

Selector notes (verified against src/search-ui.ts):
- Results list: ``.engram-search-results`` — present and empty on a blank
  query. ``renderEmpty()`` clears it and renders nothing else.
- ``.engram-search-empty`` now appears ONLY for "No results found" after a
  real query. It no longer marks the blank-query state (Engram-obsidian#503
  dropped that paragraph as a duplicate of the input placeholder).
"""

from __future__ import annotations

import asyncio

import pytest


# ---------------------------------------------------------------------------
# Capability gate
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _close_open_modals(cdp) -> None:
    """Dispatch Escape on any open modal to dismiss it cleanly."""
    await cdp.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_search_modal_empty_query_renders_no_results_row(cdp_a):
    """Empty-query state renders an EMPTY results list, not a hint paragraph.

    This used to assert a ``<p class="engram-search-empty">`` reading "Type to
    search your vault".  That paragraph was removed (Engram-obsidian#503): the
    search box placeholder already says it, and the sentence pushed the results
    down the moment anyone started typing.  ``renderEmpty()`` now just clears
    the list.

    Asserting the ABSENCE alone would pass on a modal that failed to render at
    all, so this pins the modal is up and its results container exists and is
    empty.  ``.engram-search-empty`` is still used for "No results found" after
    a real query, which is why it cannot simply be asserted absent everywhere.
    """
    try:
        await cdp_a.open_search_modal()
        await cdp_a.wait_for_search_modal()

        # Ensure input is empty (it should be on fresh open, but be explicit).
        await cdp_a.type_search_query("")
        await asyncio.sleep(0.5)

        results_children = await cdp_a.evaluate(
            "(() => {"
            "  const r = document.querySelector("
            "    '.engram-search-modal .engram-search-results');"
            "  return r ? r.children.length : -1;"
            "})()"
        )
        assert results_children == 0, (
            "Empty query should leave the results list present but empty; "
            f"got {results_children} (-1 = container missing, modal did not render)"
        )
    finally:
        await _close_open_modals(cdp_a)
