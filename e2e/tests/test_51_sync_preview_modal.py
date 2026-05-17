"""Test 51: SyncPreviewModal end-to-end coverage.

The bootstrap fixture accepts the sync gate automatically (production
steady-state for an onboarded user). These tests reset the gate to
exercise the modal explicitly, then drive it through CDP the same way a
real user click would.

Covers:
- Modal appears on a fresh fingerprint with first-time copy
- Each option choice dispatches the correct engine method
- Destructive choices require a confirm click
- Cancel keeps the gate closed
- Gate persists across plugin reload
- Vault-switch reopens the modal with vault-switch copy
"""

from __future__ import annotations

import json

import pytest

from helpers.vault import write_note


async def _dismiss_via_escape(cdp) -> None:
    """Dispatch Escape on any open modal — resolves awaitChoice as 'cancel'."""
    await cdp.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )


@pytest.mark.asyncio
async def test_modal_appears_on_first_sync(vault_a, cdp_a):
    """Reset gate, trigger sync, modal mounts with first-time header."""
    await cdp_a.reset_sync_gate()
    await cdp_a.open_sync_preview_modal()
    await cdp_a.wait_for_sync_preview_modal()

    header = await cdp_a.get_modal_header_text()
    assert "Set up sync" in header, (
        f"Expected first-time header, got: {header!r}"
    )
    assert await cdp_a.is_sync_blocked()

    await _dismiss_via_escape(cdp_a)
    await cdp_a.wait_for_modal_closed()
    await cdp_a.accept_sync_gate()


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
    vault_a, cdp_a, api_sync, label, expected_choice, destructive
):
    """Clicking each option resolves the modal with the matching choice."""
    # Seed local content so non-empty options render and any deletion
    # confirm view has at least one row to summarize.
    write_note(vault_a, f"E2E/Modal/{expected_choice}.md", "# Modal dispatch")

    await cdp_a.install_choice_spy()
    try:
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
        await cdp_a.uninstall_choice_spy()
        await cdp_a.accept_sync_gate()


@pytest.mark.asyncio
async def test_cancel_keeps_gate_closed(vault_a, cdp_a):
    """Escape-dismiss leaves syncBlocked=true (modal returns 'cancel')."""
    await cdp_a.reset_sync_gate()
    await cdp_a.open_sync_preview_modal()
    await cdp_a.wait_for_sync_preview_modal()

    await _dismiss_via_escape(cdp_a)
    await cdp_a.wait_for_modal_closed()

    assert await cdp_a.is_sync_blocked(), (
        "Sync gate must stay closed after a cancel"
    )
    await cdp_a.accept_sync_gate()


@pytest.mark.asyncio
async def test_gate_persists_across_plugin_reload(vault_a, cdp_a):
    """An accepted gate survives a plugin disable/enable cycle."""
    # accept_sync_gate ran during bootstrap; reload should preserve it.
    assert not await cdp_a.is_sync_blocked()

    await cdp_a.reload_plugin()
    # accept_sync_gate again because reload_plugin restarts the engine
    # and the on-disk fingerprint must still match the recomputed one.
    assert not await cdp_a.is_sync_blocked(), (
        "Reload should not re-block when the saved fingerprint still matches"
    )
    modal_present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.engram-sync-preview-modal'))"
    )
    assert modal_present is False


@pytest.mark.asyncio
async def test_vault_switch_reopens_modal(vault_a, cdp_a):
    """Changing vaultId after acceptance produces vault-switch copy."""
    # Bootstrap state: gate accepted for fingerprint(apiKey, vaultId).
    # Simulate the post-accept vault swap that real "Change vault" does:
    # mutate vaultId, leave syncGateAcceptedFor in place. Next applySyncGate
    # will see fingerprint mismatch -> gate closed, modal opens with the
    # vault-switch header.
    original_vault_id = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].settings.vaultId"
    )
    try:
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
            f"{json.dumps(original_vault_id)}"
        )
        await cdp_a.accept_sync_gate()
