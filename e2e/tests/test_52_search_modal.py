"""Test 52: SearchModal UI coverage.

Covers the ``Semantic search`` command opening SearchModal and the empty-state
hint rendered when the query field is blank.

The indexed-note round-trip variant (write → sync → poll /search → assert
result) was removed: it depends on the Ollama embedding pipeline indexing a
note within a bounded CI window, which is fundamentally non-deterministic
(third-party process timing, not plugin behaviour).  Search-result rendering
is exercised by the deterministic API-level test in ``test_search.py`` /
``tests/search.test.ts`` (unit) — there is no value in a flaky e2e duplicate.

Selector notes (verified against src/search-modal.ts):
- Empty-state paragraph: ``.engram-search-empty``
  (confirmed renderEmpty() / renderResults() in the source).
"""

from __future__ import annotations

import asyncio

import pytest


# ---------------------------------------------------------------------------
# Capability gate
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_search(cdp_a):
    """Skip the whole module when the loaded plugin predates SearchModal."""
    if not await cdp_a.has_search_modal():
        pytest.skip("Plugin lacks Semantic search command — skipping test_52")


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
async def test_search_modal_empty_query_shows_hint(cdp_a):
    """Empty-query state renders the placeholder paragraph.

    When the input is blank the modal calls renderEmpty() which creates a
    ``<p class="engram-search-empty">`` with the hint text.  We verify the
    element is present without making any server round-trips.
    """
    try:
        await cdp_a.open_search_modal()
        await cdp_a.wait_for_search_modal()

        # Ensure input is empty (it should be on fresh open, but be explicit).
        await cdp_a.type_search_query("")
        await asyncio.sleep(0.5)

        empty_visible = await cdp_a.evaluate(
            "Boolean(document.querySelector("
            "'.engram-search-modal .engram-search-empty'))"
        )
        assert empty_visible, (
            "Empty-state hint (.engram-search-empty) should render for empty query"
        )
    finally:
        await _close_open_modals(cdp_a)
