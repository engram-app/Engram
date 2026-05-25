"""Test 54: ConflictModal UI interactions.

Covers five user-facing paths in the ConflictModal:

1. View toggle — switch between Unified and Side-by-side layouts.
2. All-local bulk button — pre-select every hunk to use the local version,
   then accept and confirm the vault file contains local content.
3. All-remote bulk button — pre-select every hunk to use the remote version,
   then accept and confirm the vault file contains remote content.
4. Per-hunk choices — pick local for hunk 0, remote for hunk 1, accept, and
   assert the merged file contains both expected fragments.
5. Manual merge editor — overwrite the editor textarea with hand-crafted
   content, accept, and assert the vault file reflects the manual edit.

Seed strategy:
  ``setup_conflict_for_a`` (helpers/conflict.py) handles the two-party seed:
  B writes the remote version and syncs to server, A writes the local version
  while outgoing sync is paused, then A pulls — divergence is detected and
  ConflictModal opens.  Each test uses a distinct file path under
  ``E2E/Conflict54/`` to avoid cross-test interference.

Selector notes (verified against src/conflict-modal.ts, task 1 gate):
- Modal root: ``.engram-conflict-modal``
- View toggle container: ``.engram-conflict-view-toggle``
- Active button has ``.is-active`` class — ``get_conflict_view_mode()`` reads
  its lowercased text and normalises to ``'unified'`` or ``'side-by-side'``.
- Bulk buttons: text-match inside ``.engram-conflict-bulk``
  (``'All local'`` / ``'All remote'``)
- Hunk controls: ``.engram-conflict-hunk-controls`` buttons with text
  ``'Use local'`` / ``'Use remote'``
- Merge editor textarea: ``.engram-conflict-merge-editor``
- Actions footer: ``.engram-conflict-actions`` — buttons ``'Apply merge'`` and
  ``'Skip'``

``wait_for_modal_closed()`` in cdp.py targets .engram-sync-preview-modal, NOT
the conflict modal.  We therefore call ``wait_for_conflict_modal_closed()``
which was added to CdpClient alongside these helpers (targets
.engram-conflict-modal).

Helper substitution note:
  ``helpers/conflict.py`` already had ``setup_conflict()`` which takes
  ``api_sync`` and uses a 3-party seed pattern.  Task 4 needs a different
  2-party flow (B → server; A local → pull), so ``setup_conflict_for_a`` and
  ``restore_after_conflict`` were added as new functions in that file.  The
  old ``setup_conflict`` is untouched.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.conflict import restore_after_conflict, setup_conflict_for_a
from helpers.vault import wait_for_content


def _unique_path(name: str) -> str:
    """A fresh conflict-test path per invocation.

    pytest-rerunfailures retries a failed test in the SAME browser process,
    so a fixed path inherits the prior attempt's syncState/baseStore. That
    leftover state makes setup_conflict_for_a's base push echo-skip
    (sync.ts: hash === existing.hash), corrupting the 3-way base premise so
    pull() auto-merges cleanly and the ConflictModal never opens. A unique
    path per attempt starts pristine, so the base push always lands and the
    divergence is a real (non-clean) conflict.
    """
    return f"E2E/Conflict54/{name}-{uuid.uuid4().hex[:8]}.md"


# ---------------------------------------------------------------------------
# Module-level autouse fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _set_modal_mode(cdp_a):
    """Switch conflict resolution to 'modal' for every test; restore on exit."""
    await cdp_a.set_conflict_resolution("modal")
    yield
    await cdp_a.set_conflict_resolution("auto")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_view_toggle_switches_mode(vault_a, vault_b, cdp_a, cdp_b):
    """Toggle button cycles between Unified and Side-by-side view modes.

    ``get_conflict_view_mode()`` returns the lowercased text of the active
    button: ``'unified'`` when the 'Unified' button is active, ``'side-by-side'``
    when the 'Side by side' (or equivalent) button is active.

    Source line (helpers/cdp.py ~858):
        return t === 'side-by-side' ? 'side-by-side' : 'unified';
    i.e. any non-'side-by-side' active-button text maps to 'unified'.
    """
    path = _unique_path("ViewToggle")
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path,
        local="# L1\nlocal content\n# L2\nshared line\n",
        remote="# L1\nremote content\n# L2\nshared line\n",
    )
    try:
        initial_mode = await cdp_a.get_conflict_view_mode()
        assert initial_mode == "unified", (
            f"Expected initial mode 'unified', got {initial_mode!r}"
        )

        await cdp_a.toggle_conflict_view()

        toggled_mode = await cdp_a.get_conflict_view_mode()
        assert toggled_mode == "side-by-side", (
            f"Expected mode 'side-by-side' after toggle, got {toggled_mode!r}"
        )
    finally:
        # Skip the conflict so the modal closes before we clean up.
        await cdp_a.click_conflict_skip()
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_all_local_then_accept_writes_local(vault_a, vault_b, cdp_a, cdp_b):
    """'All local' bulk button pre-selects every hunk; accept writes local content.

    After clicking 'All local' and 'Apply merge', the vault file on A must
    contain the local text and NOT contain the remote-only text.
    """
    path = _unique_path("AllLocal")
    local = "# H1\nlocal-A content\n"
    remote = "# H1\nremote-B content\n"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        await cdp_a.click_all_local()
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_conflict_modal_closed()

        # wait_for_content polls: the merge's vault.modify() flush is async
        # and can lag the modal-closed signal, so a bare read races the write.
        content = wait_for_content(vault_a, path, "local-A content", timeout=10)
        assert "remote-B content" not in content, (
            f"Remote text should not appear after All-local accept; "
            f"got: {content[:200]!r}"
        )
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_all_remote_then_accept_writes_remote(vault_a, vault_b, cdp_a, cdp_b):
    """'All remote' bulk button pre-selects every hunk; accept writes remote content.

    After clicking 'All remote' and 'Apply merge', the vault file on A must
    contain the remote text and NOT contain the local-only text.
    """
    path = _unique_path("AllRemote")
    local = "# H1\nlocal-A content\n"
    remote = "# H1\nremote-B content\n"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        await cdp_a.click_all_remote()
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_conflict_modal_closed()

        content = wait_for_content(vault_a, path, "remote-B content", timeout=10)
        assert "local-A content" not in content, (
            f"Local text should not appear after All-remote accept; "
            f"got: {content[:200]!r}"
        )
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_per_hunk_choices_mixed_then_accept(vault_a, vault_b, cdp_a, cdp_b):
    """Per-hunk choices: local for hunk 0, remote for hunk 1; merged result.

    Seed shape: the two diverged regions are separated by 10+ lines of
    identical unchanged context so diff-match-patch's hunk grouping cannot
    collapse them into a single hunk. With sufficient context distance the
    plugin's groupIntoHunks() emits a separate hunk per diverged region.
    """
    path = _unique_path("PerHunk")
    # 12 identical unchanged lines between the two diverged regions force
    # the diff grouper to emit two distinct hunks rather than fusing them.
    middle = "\n".join(f"context line {i}" for i in range(1, 13))
    local = (
        "# H1\n"
        "local-region-A\n"
        f"{middle}\n"
        "# H2\n"
        "local-region-B\n"
    )
    remote = (
        "# H1\n"
        "remote-region-A\n"
        f"{middle}\n"
        "# H2\n"
        "remote-region-B\n"
    )
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        # Verify we actually got ≥2 hunks — fail loudly if the grouping
        # rules change and collapse them again, instead of silently
        # producing the wrong merged content via a no-op pick_conflict_hunk(1).
        hunk_count = await cdp_a.evaluate(
            "document.querySelectorAll("
            "'.engram-conflict-modal .engram-conflict-hunk').length"
        )
        assert hunk_count >= 2, (
            f"Seed produced {hunk_count} hunk(s); test requires ≥2. "
            f"diff-match-patch grouping may have changed; add more "
            f"separator lines."
        )

        await cdp_a.pick_conflict_hunk(0, "local")
        await cdp_a.pick_conflict_hunk(1, "remote")
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_conflict_modal_closed()

        # Poll for the async vault.modify() flush. Wait on the LAST-written
        # region (hunk 1, end of file): vault.modify writes front-to-back, so
        # if 'remote-region-B' is visible the earlier 'local-region-A' is too.
        # Waiting on the leading region instead would leave a truncated-read
        # window where hunk 0 is present but hunk 1 isn't yet flushed.
        merged = wait_for_content(vault_a, path, "remote-region-B", timeout=10)
        assert "local-region-A" in merged, (
            f"Expected 'local-region-A' (hunk 0 local choice) in merged; "
            f"got: {merged[:400]!r}"
        )
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_manual_merge_editor_then_accept(vault_a, vault_b, cdp_a, cdp_b):
    """Manual merge editor textarea accepts arbitrary content; accept writes it.

    Overwrites the merge editor with hand-crafted text and confirms the vault
    file reflects exactly that content after 'Apply merge'.
    """
    path = _unique_path("ManualEditor")
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path,
        local="# H1\nlocal edit\n",
        remote="# H1\nremote edit\n",
    )
    try:
        hand_edited = "# H1\nhand-edited by test_54\n"
        await cdp_a.set_merge_editor(hand_edited)
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_conflict_modal_closed()

        # Use wait_for_content instead of read_note: the modal closes (DOM
        # removal) before Obsidian's async vault.modify() flushes to disk.
        content = wait_for_content(vault_a, path, "hand-edited by test_54", timeout=10)
        assert "hand-edited by test_54" in content, (
            f"Expected hand-edited content in vault; got: {content[:200]!r}"
        )
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)
