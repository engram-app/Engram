"""Test 51: SyncPreviewModal end-to-end coverage.

The bootstrap fixture accepts the sync gate automatically (production
steady-state for an onboarded user). These tests reset the gate to
exercise the modal explicitly, then drive it through CDP the same way a
real user click would.

Seed pattern: with the gate already accepted, `pause_outgoing_sync`
stubs the push handlers so vault writes stay local, then `write_note`
creates a divergent file the planner will summarize, then
`reset_sync_gate` re-blocks the engine so opening the modal computes
a non-empty plan. (When the plan is empty the modal renders the
"Everything is in sync" header and a single Close button — the option
buttons aren't rendered at all.)

Covers:
- Modal mounts with first-time copy when no fingerprint is saved
- Each option resolves runSyncFromChoice with the matching choice
- Destructive choices require a confirm click
- Escape-dismissal keeps the gate closed
- Gate persists across plugin reload
- Vault-switch reopens the modal with vault-switch copy
"""

from __future__ import annotations

import json

import pytest

from helpers.vault import write_note


SEED_DIR = "E2E/Modal"


async def _dismiss_via_escape(cdp) -> None:
    """Dispatch Escape until every modal layer is gone.

    Delegates to `cdp.dismiss_modals()` which polls + retries — robust against
    stacked modal views where a single Escape only collapses one layer.
    """
    await cdp.dismiss_modals()


async def _vault_create(cdp, path: str, content: str) -> None:
    """Create a file via app.vault.create (test_55's pattern).

    Raw filesystem writes don't show in app.vault.getFiles() until the
    watcher fires — computeSyncPlan reads getFiles(), so a raw write can
    race the plan and make the local side look empty (which plugin #415
    then collapses into the one-click screen with no option cards).
    """
    await cdp.evaluate(
        f"""
        (async () => {{
            const path = {json.dumps(path)};
            const content = {json.dumps(content)};
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


async def _vault_delete(cdp, vault, path: str) -> None:
    """Delete via app.vault.delete so Obsidian's index drops the file BEFORE
    sync resumes — a raw unlink leaves the file in getFiles() until the
    watcher fires and the resumed engine can push the ghost back. Filesystem
    unlink is the fallback for files a sync action already removed."""
    await cdp.evaluate(
        f"""
        (async () => {{
            const f = app.vault.getFileByPath({json.dumps(path)});
            if (f) {{ try {{ await app.vault.delete(f); }} catch (_) {{}} }}
        }})()
        """,
        await_promise=True,
    )
    file_path = vault / path
    if file_path.exists():
        file_path.unlink()


async def _seed_local_only(cdp, vault, path: str, content: str) -> None:
    """Create a file in the vault that does NOT propagate to the server.

    Pauses push handlers, writes (via app.vault so the plan sees it
    synchronously), resets the gate. The reset both re-blocks the engine
    and clears the saved fingerprint so the next modal render is in the
    "first-time" branch unless caller patches syncGateAcceptedFor.
    """
    await cdp.pause_outgoing_sync()
    await _vault_create(cdp, path, content)
    await cdp.reset_sync_gate()


async def _restore_clean(cdp, vault, path: str) -> None:
    """Undo _seed_local_only: delete the seeded file, resume push, re-accept."""
    await _vault_delete(cdp, vault, path)
    await cdp.resume_outgoing_sync()
    await cdp.accept_sync_gate()


async def _seed_divergent(cdp, vault, api_sync, local_path: str, remote_path: str) -> None:
    """Seed BOTH a local-only and a remote-only file (test_55's pattern).

    The option-card tests need the five-option modal, and plugin #415
    collapses any one-empty-side plan into a one-click screen with no
    option cards. Populating both sides keeps the full modal rendering
    on every plugin version.
    """
    await cdp.pause_outgoing_sync()
    await _vault_create(cdp, local_path, "# local-only dispatch seed\n")
    api_sync.create_note(remote_path, "# remote-only dispatch seed\n")
    await cdp.reset_sync_gate()


async def _restore_divergent(cdp, vault, api_sync, local_path: str, remote_path: str) -> None:
    """Undo _seed_divergent: delete both seeds, resume push, re-accept.

    The remote delete must be LOUD on failure: delete_note returns the
    HTTP status without raising, and a silently leaked remote seed makes
    this worker's server vault permanently non-empty (which silently
    skips the one-click screen test forever after).
    """
    await _vault_delete(cdp, vault, local_path)
    status = api_sync.delete_note(remote_path)
    assert status in (200, 204, 404), (
        f"remote seed cleanup failed: DELETE {remote_path} -> {status}"
    )
    await cdp.resume_outgoing_sync()
    await cdp.accept_sync_gate()


@pytest.mark.asyncio
async def test_modal_appears_on_first_sync(vault_a, cdp_a):
    """Reset gate with divergent local state, modal mounts with first-time header."""
    path = f"{SEED_DIR}/AppearsFirstSync.md"
    await _seed_local_only(cdp_a, vault_a, path, "# First-sync seed")
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        header = await cdp_a.get_modal_header_text()
        assert "Set up sync" in header, (
            f"Expected first-time header, got: {header!r}"
        )
        assert await cdp_a.is_sync_blocked()

        await _dismiss_via_escape(cdp_a)
    finally:
        await _restore_clean(cdp_a, vault_a, path)


DISPATCH_LOCAL = f"{SEED_DIR}/Dispatch-local.md"
DISPATCH_REMOTE = f"{SEED_DIR}/Dispatch-remote.md"


@pytest.fixture(scope="module")
async def dispatch_seed(vault_a, cdp_a, api_sync):
    """One divergent seed shared by all 5 dispatch params (test_55's pattern).

    install_choice_spy(swallow=True) means no param mutates the seed, so
    seeding once saves ~10s of suite time — and restoring in a fixture
    finalizer (not a per-test finally) guarantees sync is resumed and the
    gate re-accepted even when a test body or its cleanup raises.
    """
    await _seed_divergent(cdp_a, vault_a, api_sync, DISPATCH_LOCAL, DISPATCH_REMOTE)
    try:
        yield (DISPATCH_LOCAL, DISPATCH_REMOTE)
    finally:
        await _restore_divergent(
            cdp_a, vault_a, api_sync, DISPATCH_LOCAL, DISPATCH_REMOTE
        )


@pytest.mark.parametrize(
    "label, expected_choice, destructive",
    [
        ("Sync", "smart-merge", False),
        ("Upload local files without downloading the remote", "push-all-keep-remote", False),
        ("Download remote files without uploading the local", "pull-all-keep-local", False),
        ("Delete all on remote, then upload local files", "push-all-delete-remote", True),
        ("Delete all local files, then download from remote", "pull-all-delete-local", True),
    ],
)
@pytest.mark.asyncio
async def test_modal_choice_dispatches(
    cdp_a, dispatch_seed, label, expected_choice, destructive
):
    """Each option resolves runSyncFromChoice with the matching choice.

    Spy swallows the original call so the chosen direction is recorded
    without actually deleting/pushing/pulling real data — the modal's
    dispatch contract is what we're asserting, not the underlying sync.
    """
    try:
        await cdp_a.install_choice_spy(swallow=True)
        # The previous param's resolved choice opened the gate — re-block so
        # the modal opens on a non-empty plan again.
        await cdp_a.reset_sync_gate()
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        await cdp_a.pick_modal_option(label)
        if destructive:
            await cdp_a.click_modal_confirm()

        await cdp_a.wait_for_modal_closed(timeout=10)

        recorded = await cdp_a.get_last_sync_choice()
        assert recorded == expected_choice, (
            f"Expected runSyncFromChoice({expected_choice!r}), got {recorded!r}"
        )
        assert not await cdp_a.is_sync_blocked(), (
            f"Gate should be open after {expected_choice} resolves"
        )
    finally:
        # Chained so a raise in one step can't skip the next: a stranded
        # modal cascades (syncPreviewGuard makes reopen a silent no-op) and
        # the fixture finalizer still restores seed/sync/gate regardless.
        try:
            await cdp_a.uninstall_choice_spy()
        finally:
            await cdp_a.dismiss_modals()


@pytest.mark.asyncio
async def test_one_click_upload_screen_dispatches_smart_merge(vault_a, cdp_a):
    """Plugin #415: an empty-remote first sync renders a one-click upload
    screen whose single button dispatches smart-merge (never a delete
    variant). Feature-detected by DOM shape: pre-#415 plugins — or a worker
    whose server vault already has notes (an xdist-position accident this
    detection can't distinguish from an old plugin) — render the five-option
    modal instead; skip there, the dispatch tests above cover that shape.
    Rendering NEITHER shape is a failure, not a skip.
    """
    path = f"{SEED_DIR}/OneClickUpload.md"
    try:
        await _seed_local_only(cdp_a, vault_a, path, "# One-click seed")
        await cdp_a.install_choice_spy(swallow=True)
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        # Poll until either screen shape renders (plan computes async).
        screen = await cdp_a.evaluate(
            """
            (async () => {
                const deadline = Date.now() + 10000;
                while (Date.now() < deadline) {
                    const modal = document.querySelector('.engram-sync-preview-modal');
                    if (modal) {
                        if (modal.querySelector('.engram-sync-preview-simple-action')) {
                            return 'simple';
                        }
                        if (modal.querySelector('.engram-sync-preview-option-label')) {
                            return 'options';
                        }
                    }
                    await new Promise(r => setTimeout(r, 200));
                }
                return 'none';
            })()
            """,
            await_promise=True,
        )
        if screen == "none":
            pytest.fail(
                "sync preview modal rendered neither the one-click screen nor "
                "option cards within 10s — plan compute or modal render broke"
            )
        if screen == "options":
            pytest.skip(
                "five-option modal rendered — pre-#415 plugin or non-empty "
                "server vault on this worker"
            )

        await cdp_a.evaluate(
            "document.querySelector("
            "'.engram-sync-preview-modal .engram-sync-preview-simple-action'"
            ").click()"
        )
        await cdp_a.wait_for_modal_closed(timeout=10)

        recorded = await cdp_a.get_last_sync_choice()
        assert recorded == "smart-merge", (
            f"One-click upload must dispatch smart-merge, got {recorded!r}"
        )
    finally:
        # Chained: each cleanup step runs even when the previous one raises.
        try:
            await cdp_a.uninstall_choice_spy()
        finally:
            try:
                await cdp_a.dismiss_modals()
            finally:
                await _restore_clean(cdp_a, vault_a, path)


@pytest.mark.asyncio
async def test_cancel_keeps_gate_closed(vault_a, cdp_a):
    """Escape-dismiss leaves syncBlocked=true (modal returns 'cancel')."""
    path = f"{SEED_DIR}/Cancel.md"
    await _seed_local_only(cdp_a, vault_a, path, "# Cancel seed")
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        await _dismiss_via_escape(cdp_a)

        assert await cdp_a.is_sync_blocked(), (
            "Sync gate must stay closed after a cancel"
        )
    finally:
        await _restore_clean(cdp_a, vault_a, path)


@pytest.mark.asyncio
async def test_gate_persists_across_plugin_reload(vault_a, cdp_a):
    """An accepted gate survives a plugin disable/enable cycle."""
    assert not await cdp_a.is_sync_blocked()

    await cdp_a.reload_plugin()

    assert not await cdp_a.is_sync_blocked(), (
        "Reload should not re-block when the saved fingerprint still matches"
    )
    modal_present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.engram-sync-preview-modal'))"
    )
    assert modal_present is False


@pytest.mark.asyncio
async def test_vault_switch_reopens_modal(vault_a, cdp_a):
    """Changing vaultId after acceptance produces vault-switch copy.

    Bootstrap state: gate accepted for fingerprint(apiKey, vaultId).
    Simulate the post-accept vault swap that real "Change vault" does:
    mutate settings.vaultId, leave syncGateAcceptedFor in place. The
    next applySyncGate sees a fingerprint mismatch — gate closes, and
    derivePreviewContext returns "vault-switch" (because the saved
    fingerprint is non-null).
    """
    path = f"{SEED_DIR}/VaultSwitch.md"

    # Snapshot the bootstrap fingerprint AND vaultId so we can restore them.
    original_vault_id = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].settings.vaultId"
    )
    original_accepted = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].syncGateAcceptedFor"
    )

    await cdp_a.pause_outgoing_sync()
    write_note(vault_a, path, "# Vault switch seed")
    try:
        # Mutate vaultId — applySyncGate will see the new fingerprint as
        # not matching the (still non-null) accepted one.
        await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync'].settings.vaultId = "
            "'__e2e_simulated_switch__'"
        )
        gate_open = await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync'].applySyncGate()"
            ".then(v => v)",
            await_promise=True,
        )
        assert gate_open is False
        assert await cdp_a.is_sync_blocked()

        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        header = await cdp_a.get_modal_header_text()
        assert "different cloud vault" in header, (
            f"Expected vault-switch header, got: {header!r}"
        )

        await _dismiss_via_escape(cdp_a)
    finally:
        await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync'].settings.vaultId = "
            f"{json.dumps(original_vault_id)};"
            "app.plugins.plugins['engram-vault-sync'].syncGateAcceptedFor = "
            f"{json.dumps(original_accepted)}"
        )
        if (vault_a / path).exists():
            (vault_a / path).unlink()
        await cdp_a.resume_outgoing_sync()
        await cdp_a.accept_sync_gate()
