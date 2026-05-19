"""Test 55: Destructive confirm view in SyncPreviewModal.

Covers the typed-"delete" gate for the two destructive sync directions:
  - push-all-delete-remote ("Push all + delete remote")
  - pull-all-delete-local  ("Pull all + delete local")

Pre-PR-61 plugins lack the typed-confirm input — skip cleanly there.

Seed sharing:
  All 3 tests need an identical divergent state (one local-only file +
  one remote-only file). The seed is expensive (~2-3 s for the
  pause-sync + vault.create + REST POST). Hoisting it into a
  module-scoped fixture saves ~6 s vs re-seeding per test.

  None of the 3 tests mutates the seed — tests 1 & 2 cancel via Escape,
  test 3 uses install_choice_spy(swallow=True) so the confirm click is
  swallowed without running the destructive sync. The seed is therefore
  safe to share.
"""

from __future__ import annotations

import json

import pytest


SEED_DIR = "E2E/Preview55"
SHARED_LOCAL = f"{SEED_DIR}/Shared-local.md"
SHARED_REMOTE = f"{SEED_DIR}/Shared-remote.md"


async def _dismiss_via_escape(cdp) -> None:
    """Dispatch Escape until no modal remains.

    SyncPreviewModal's destructive view is stacked on top of the option-pick
    view — a single Escape only collapses the confirm view. Use the helper's
    bounded retry loop so we peel every layer off without timing guesswork.
    """
    await cdp.dismiss_modals()


async def _seed_divergent(
    cdp, vault, api_sync, local_path: str, remote_path: str
) -> None:
    """Produce a plan with BOTH a local-only and a remote-only file.

    Why both sides:
      - "Push all + delete remote" only renders meaningfully when the plan has
        a non-zero ``deleteRemoteCount`` (i.e. at least one path lives ONLY on
        the server).
      - "Pull all + delete local" only renders meaningfully when the plan has
        a non-zero ``deleteLocalCount`` (i.e. at least one path lives ONLY in
        the vault).

    Steps:
      1. Pause outgoing sync so the local write stays off-server.
      2. Create ``local_path`` via ``app.vault.create()`` so Obsidian's index
         sees it immediately (raw filesystem writes don't show in
         ``getFiles()`` until the watcher fires — that race is what made the
         destructive option occasionally invisible).
      3. Create ``remote_path`` on the server directly via the REST API.
      4. Reset the sync gate so SyncPreviewModal opens on next dispatch.
    """
    await cdp.pause_outgoing_sync()
    # Use app.vault.create so the file is in app.vault.getFiles() immediately —
    # computeSyncPlan reads getFiles() and needs the file present synchronously
    # or the plan is empty and the modal renders "up-to-date".
    await cdp.evaluate(
        f"""
        (async () => {{
            const path = {json.dumps(local_path)};
            const content = '# local-only\\nseed for sync-preview test\\n';
            const slash = path.lastIndexOf('/');
            if (slash > 0) {{
                const dir = path.slice(0, slash);
                if (!app.vault.getAbstractFileByPath(dir)) {{
                    try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
                }}
            }}
            const existing = app.vault.getFileByPath(path);
            if (existing) {{
                await app.vault.modify(existing, content);
            }} else {{
                await app.vault.create(path, content);
            }}
        }})()
        """,
        await_promise=True,
    )
    api_sync.create_note(remote_path, "# remote-only\nseed for sync-preview test\n")
    await cdp.reset_sync_gate()


async def _restore_divergent(
    cdp, vault, api_sync, local_path: str, remote_path: str
) -> None:
    """Undo ``_seed_divergent``: delete both seeds, resume push, re-accept gate."""
    # Delete via app.vault so Obsidian's index is kept in sync. Fall back to
    # filesystem unlink in case the file was already removed by a sync action.
    await cdp.evaluate(
        f"""
        (async () => {{
            const f = app.vault.getFileByPath({json.dumps(local_path)});
            if (f) {{ try {{ await app.vault.delete(f); }} catch (_) {{}} }}
        }})()
        """,
        await_promise=True,
    )
    file_path = vault / local_path
    if file_path.exists():
        file_path.unlink()
    # The remote-only file should be torn down server-side so it does not
    # bleed into other tests' plans.
    try:
        api_sync.delete_note(remote_path)
    except Exception:
        # Idempotent — ignore 404 / already-deleted etc.
        pass
    await cdp.resume_outgoing_sync()
    await cdp.accept_sync_gate()


@pytest.fixture(scope="module")
async def divergent_seed(vault_a, cdp_a, api_sync):
    """One divergent seed shared by all 3 tests in this module.

    None of the tests mutates the seed (tests 1 & 2 Escape, test 3 uses
    install_choice_spy(swallow=True)), so we pay the seed cost once and
    save ~6 s per-suite-run vs reseeding per test.
    """
    await _seed_divergent(cdp_a, vault_a, api_sync, SHARED_LOCAL, SHARED_REMOTE)
    try:
        yield (SHARED_LOCAL, SHARED_REMOTE)
    finally:
        await _restore_divergent(
            cdp_a, vault_a, api_sync, SHARED_LOCAL, SHARED_REMOTE
        )


@pytest.mark.parametrize(
    "label",
    [
        "Push all + delete remote",
        "Pull all + delete local",
    ],
)
@pytest.mark.asyncio
async def test_destructive_submit_locked_until_typed(
    cdp_a, divergent_seed, label
):
    """Submit button stays disabled until "delete" is typed exactly.

    Flow:
      1. Open modal against the module-scoped divergent seed (both
         destructive options render with non-zero counts).
      2. Pick the destructive option — confirm view appears.
      3. Assert button disabled before any text.
      4. Type partial word "delet" — still disabled.
      5. Type full word "delete" — enabled.
      6. Escape to cancel — gate stays closed and seed is preserved for
         the next test.
    """
    await cdp_a.open_sync_preview_modal()
    await cdp_a.wait_for_sync_preview_modal()
    await cdp_a.pick_modal_option(label)

    try:
        assert not await cdp_a.destructive_submit_enabled(), (
            "Submit must be disabled before user types 'delete'"
        )

        await cdp_a.type_destructive_confirm("delet")
        assert not await cdp_a.destructive_submit_enabled(), (
            "Submit must remain disabled for partial input 'delet'"
        )

        await cdp_a.type_destructive_confirm("delete")
        assert await cdp_a.destructive_submit_enabled(), (
            "Submit must be enabled once 'delete' is typed exactly"
        )

        # Cancel via Escape — gate must stay closed (no sync dispatched)
        # and the seed must persist for the next test. `dismiss_modals` polls
        # until the DOM is fully empty, so no extra `wait_for_modal_closed`
        # call is needed.
        await _dismiss_via_escape(cdp_a)
        assert await cdp_a.is_sync_blocked(), (
            "Sync gate must remain blocked after cancel via Escape"
        )
    finally:
        # Belt-and-braces: ensure no modal is left open even if an
        # assertion failed mid-flow. Don't reseed — the next test wants
        # the same divergent state.
        await _dismiss_via_escape(cdp_a)


@pytest.mark.asyncio
async def test_destructive_confirm_dispatches_choice(cdp_a, divergent_seed):
    """Full flow: pick destructive option → type "delete" → submit → choice recorded.

    Uses the choice spy (swallow=True) so no real sync runs and the
    shared seed is preserved.
    Asserts the dispatched choice is "push-all-delete-remote".
    """
    await cdp_a.install_choice_spy(swallow=True)
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        await cdp_a.pick_modal_option("Push all + delete remote")
        await cdp_a.type_destructive_confirm("delete")
        await cdp_a.click_modal_confirm()

        await cdp_a.wait_for_modal_closed(timeout=10)

        recorded = await cdp_a.get_last_sync_choice()
        assert recorded == "push-all-delete-remote", (
            f"Expected runSyncFromChoice('push-all-delete-remote'), got {recorded!r}"
        )
    finally:
        await cdp_a.uninstall_choice_spy()
