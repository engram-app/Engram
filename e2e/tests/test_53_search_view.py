"""Test 53: SearchView sidebar UI coverage.

Covers two deterministic user paths:
1. ``Open search sidebar`` command mounts the SearchView leaf.
2. Ribbon icon (aria-label "Engram search") opens the same sidebar view.

The ``sidebar query returns results for an indexed note`` variant was removed:
it depended on the Ollama embedding pipeline indexing a note within a bounded
CI window, which is fundamentally non-deterministic (third-party process
timing, not plugin behaviour). Search-result rendering is exercised by the
deterministic API-level unit test in ``tests/search.test.ts`` — there is no
value in a flaky e2e duplicate of that path.

Selector notes (verified against src/search-view.ts, SEARCH_VIEW_TYPE const):
- View type id: ``engram-search-view``
- Workspace leaf selector: ``.workspace-leaf-content[data-type="engram-search-view"]``

Ribbon note: aria-label is "Engram search" (src/main.ts line 298).
The ``click_ribbon()`` helper matches any label that includes "Engram".
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Capability gate
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_sidebar(cdp_a):
    """Skip the whole module when the loaded plugin predates SearchView."""
    if not await cdp_a.has_command("open-search-sidebar"):
        pytest.skip(
            "Plugin lacks open-search-sidebar command — skipping test_53"
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_command_opens_sidebar(cdp_a):
    """``open-search-sidebar`` command mounts the SearchView leaf."""
    await cdp_a.open_search_sidebar()
    await cdp_a.wait_for_search_view()

    present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.workspace-leaf-content"
        "[data-type=\"engram-search-view\"]'))"
    )
    assert present, (
        "SearchView leaf (.workspace-leaf-content[data-type='engram-search-view'])"
        " not found after open-search-sidebar command"
    )


@pytest.mark.asyncio
async def test_ribbon_opens_sidebar(cdp_a):
    """Ribbon icon (aria-label contains 'Engram') opens the SearchView sidebar.

    Skips gracefully when the ribbon icon is not registered in the loaded
    plugin build (legitimate capability gate — pre-ribbon plugin builds).
    """
    if not await cdp_a.has_ribbon():
        pytest.skip("Ribbon icon not registered in this plugin build")

    await cdp_a.click_ribbon()
    await cdp_a.wait_for_search_view()

    present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.workspace-leaf-content"
        "[data-type=\"engram-search-view\"]'))"
    )
    assert present, "SearchView leaf not found after ribbon click"
