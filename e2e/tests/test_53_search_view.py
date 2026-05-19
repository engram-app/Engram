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
    """Ribbon icon (aria-label contains 'Engram') opens the SearchView sidebar."""
    await cdp_a.click_ribbon()
    await cdp_a.wait_for_search_view()

    present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.workspace-leaf-content"
        "[data-type=\"engram-search-view\"]'))"
    )
    assert present, "SearchView leaf not found after ribbon click"
