"""Test 52: SearchModal end-to-end coverage.

Covers the ``Semantic search`` command opening SearchModal, typing a query,
the 300 ms debounce, results rendering, and the empty-state hint shown when
the query field is blank.

Seed strategy: write a known note to the vault via write_note, trigger a full
sync so the plugin pushes it to the backend, then poll the server-side
``/search`` endpoint until the embedding pipeline has indexed the note (up to
30 s).  Only then open the modal and assert the result appears.

Selector notes (corrected from plan draft — see Task 1 commit 9735baa):
- Result items: ``.engram-search-result-item``
  (plan draft used ``.engram-search-result`` which does not exist in source)
- Title, path, snippet children: ``.engram-search-result-title``,
  ``.engram-search-result-path``, ``.engram-search-result-snippet``
- Empty-state paragraph: ``.engram-search-empty``
  (confirmed in src/search-modal.ts renderEmpty() and renderResults())

Indexing-wait concern: 30 s is the plan's directive.  The Qdrant embedding
pipeline can be slower under heavy CI load.  If this test flaps with
``Backend never indexed seed note`` the deadline should be raised to 60 s and
the poll interval may need backing off to avoid hammering the server.
"""

from __future__ import annotations

import asyncio
import time

import pytest

from helpers.vault import write_note


SEED_DIR = "E2E/SearchModal"

# Unique token unlikely to appear in any other vault note.
_UNIQUE_TOKEN = "UniqueQueryToken-XYZZY42"


@pytest.fixture(autouse=True)
async def _require_search(cdp_a):
    """Skip the whole module when the loaded plugin predates SearchModal.

    The ``engram-vault-sync:search`` command was added in a later PR. Pre-PR
    plugin builds in CI will lack it; detect once and skip cleanly rather than
    failing in setup.
    """
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
async def test_search_modal_returns_indexed_note(vault_a, cdp_a, api_sync):
    """Indexed-note round-trip: write → sync → wait for indexing → open modal → assert result.

    The seed note contains a unique token that will not match any other vault
    content.  After full sync the embedding pipeline indexes it; we poll via
    the REST API until the token appears in search results, then drive the
    modal via CDP.
    """
    path = f"{SEED_DIR}/UniqueQueryToken-XYZZY42.md"
    content = (
        "# Photosynthesis primer\n\n"
        f"{_UNIQUE_TOKEN} anchors this test.\n"
    )
    write_note(vault_a, path, content)
    await cdp_a.trigger_full_sync()

    # Poll server-side until the embedding pipeline indexes the note.
    # Deadline: 30 s per plan directive.
    deadline = time.monotonic() + 30
    indexed = False
    while time.monotonic() < deadline:
        hits = api_sync.search(_UNIQUE_TOKEN)
        if hits:
            indexed = True
            break
        await asyncio.sleep(1)

    if not indexed:
        # Clean up before failing so subsequent tests are not polluted.
        (vault_a / path).unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()
        pytest.fail(
            f"Backend never indexed seed note within 30 s "
            f"(token: {_UNIQUE_TOKEN!r})"
        )

    try:
        await cdp_a.open_search_modal()
        await cdp_a.wait_for_search_modal()
        await cdp_a.type_search_query(_UNIQUE_TOKEN)

        # Debounce is 300 ms + async fetch; wait 1.5 s to let results settle.
        await asyncio.sleep(1.5)

        results = await cdp_a.get_search_results()
        titles = [r.get("title", "") for r in results]
        assert any(_UNIQUE_TOKEN in t for t in titles), (
            f"Expected seed note (title containing {_UNIQUE_TOKEN!r}) in "
            f"search results, got: {results!r}"
        )
    finally:
        await _close_open_modals(cdp_a)
        (vault_a / path).unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()


@pytest.mark.asyncio
async def test_search_modal_empty_query_shows_hint(cdp_a):
    """Empty-query state renders the placeholder paragraph.

    When the input is blank the modal calls renderEmpty() which creates a
    ``<p class="engram-search-empty">`` with the hint text.  We verify the
    element is present without making any server round-trips.

    Source reference: src/search-modal.ts renderEmpty() — class confirmed
    ``.engram-search-empty`` exists for both the initial empty state and the
    ``No results found`` state after a query that returns zero hits.
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
