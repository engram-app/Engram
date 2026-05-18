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


@pytest.fixture(autouse=True)
async def _require_sync_gate(cdp_a):
    """Skip the whole module when the loaded plugin predates SyncPreviewModal.

    Backend CI runs this suite against whichever plugin SHA the cross-repo
    trigger ships. Pre-PR-61 plugin builds have no gate API, so every
    test_51 case would explode in setup. Detect once, skip cleanly.
    """
    if not await cdp_a.has_sync_gate():
        pytest.skip("Plugin lacks SyncPreviewModal — gate API not present")


async def _dismiss_via_escape(cdp) -> None:
    """Dispatch Escape on any open modal — resolves awaitChoice as 'cancel'."""
    await cdp.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )


async def _seed_local_only(cdp, vault, path: str, content: str) -> None:
    """Create a file in the vault that does NOT propagate to the server.

    Pauses push handlers, writes, resets the gate. The reset both
    re-blocks the engine and clears the saved fingerprint so the next
    modal render is in the "first-time" branch unless caller patches
    syncGateAcceptedFor.
    """
    await cdp.pause_outgoing_sync()
    write_note(vault, path, content)
    await cdp.reset_sync_gate()


async def _restore_clean(cdp, vault, path: str) -> None:
    """Undo _seed_local_only: delete the seeded file, resume push, re-accept."""
    file_path = vault / path
    if file_path.exists():
        file_path.unlink()
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
        await cdp_a.wait_for_modal_closed()
    finally:
        await _restore_clean(cdp_a, vault_a, path)


@pytest.mark.parametrize(
    "label, expected_choice, destructive",
    [
        ("Merge", "smart-merge", False),
        ("Push all + keep remote", "push-all-keep-remote", False),
        ("Pull all + keep local", "pull-all-keep-local", False),
        ("Push all + delete remote", "push-all-delete-remote", True),
        ("Pull all + delete local", "pull-all-delete-local", True),
    ],
)
@pytest.mark.asyncio
async def test_modal_choice_dispatches(
    vault_a, cdp_a, label, expected_choice, destructive
):
    """Each option resolves runSyncFromChoice with the matching choice.

    Spy swallows the original call so the chosen direction is recorded
    without actually deleting/pushing/pulling real data — the modal's
    dispatch contract is what we're asserting, not the underlying sync.
    """
    path = f"{SEED_DIR}/Dispatch-{expected_choice}.md"
    await _seed_local_only(cdp_a, vault_a, path, "# Dispatch seed")
    await cdp_a.install_choice_spy(swallow=True)
    try:
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
        await cdp_a.uninstall_choice_spy()
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
        await cdp_a.wait_for_modal_closed()

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
        assert "New vault detected" in header, (
            f"Expected vault-switch header, got: {header!r}"
        )

        await _dismiss_via_escape(cdp_a)
        await cdp_a.wait_for_modal_closed()
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
