"""Test 58: Plugin command palette entries each fire their handler.

Covers the four commands not already tested elsewhere:
  sync-now        — pulls a pending server change down into the vault
  push-all        — pushAll() is invoked on SyncEngine (spy counter)
  pull-all        — pullAll() is invoked on SyncEngine (spy counter)
  show-sync-log   — .engram-sync-log-modal mounts in the DOM

# NOTE: test_check_sync_emits_notice was removed in PR #148 — require('obsidian')
# is not available in CDP scope; DOM-polling and constructor-patch fallbacks
# both flake. The check-sync command is exercised indirectly by the sync
# integration tests.

Commands search, open-search-sidebar, and open-sync-center are skipped here
because they are already covered by test_52, test_53, and test_56 respectively.

Seed/restore rationale:
  These tests do not mutate vault files — they only exercise command dispatch
  and short-lived DOM/JS side effects. No vault file restore is needed.
  Each test installs a spy or wrapper in try/finally so cleanup is guaranteed
  even on assertion failure.

Notice observation rationale:
  Notice is imported from the 'obsidian' CommonJS module inside Electron, not
  a global. The CDP Runtime.evaluate scope is a different realm and ``require``
  is not available there, so we cannot monkey-patch the Notice constructor.
  Instead, we poll the DOM for ``.notice`` elements which Obsidian's Notice
  class renders into the notice container at the document root. This is the
  same affordance Obsidian's own users observe and is the most robust signal.
"""

from __future__ import annotations
import asyncio
import uuid

import pytest
from helpers.vault import wait_for_content


# ---------------------------------------------------------------------------
# test_sync_now_pulls_pending_change
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_sync_now_pulls_pending_change(vault_a, cdp_a, api_sync):
    """sync-now: the command runs a sync that pulls a pending server change.

    Post-B2, lastSync is frozen (the opaque syncCursor is the watermark), so
    "lastSync advances" is no longer a valid signal. Instead we create a note
    on the server out-of-band, fire sync-now, and assert the pull lands the
    note in the local vault — a behavior assertion that holds regardless of
    cursor internals.
    """
    unique = uuid.uuid4().hex[:12]
    path = f"E2E/SyncNowCmd-{unique}.md"
    marker = f"sync-now pull marker {unique}"
    content = f"# Sync Now Command\n{marker}"

    # Create the note server-side (out-of-band — not via the local vault).
    api_sync.create_note(path, content)

    # Fire the command under test.
    await cdp_a.run_command("sync-now")

    # The note must arrive locally as a result of the sync the command ran.
    local = wait_for_content(vault_a, path, marker, timeout=15)
    assert marker in local, (
        f"sync-now did not pull pending server change into {path!r}"
    )


# ---------------------------------------------------------------------------
# test_push_all_invokes_handler
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_push_all_invokes_handler(cdp_a):
    """push-all: pushAll() on SyncEngine is called at least once."""
    # Install spy — capture original so we can restore exactly.
    # Wrap in IIFE so `const` declarations don't leak into the shared
    # renderer execution context (would clash on re-runs / sequential evals).
    await cdp_a.evaluate(
        "(() => {"
        "  window.__e2e_pushAll_count = 0;"
        "  const _p = app.plugins.plugins['engram-vault-sync'];"
        "  window.__e2e_pushAll_orig = _p.syncEngine.pushAll.bind(_p.syncEngine);"
        "  _p.syncEngine.pushAll = async (...a) => {"
        "    window.__e2e_pushAll_count++;"
        "    return window.__e2e_pushAll_orig(...a);"
        "  };"
        "})()"
    )
    try:
        await cdp_a.run_command("push-all")
        # Command callback is async — poll briefly
        called = 0
        for _ in range(20):
            called = await cdp_a.evaluate("window.__e2e_pushAll_count")
            if called >= 1:
                break
            await asyncio.sleep(0.25)
        assert called >= 1, f"pushAll was not called (count={called})"
    finally:
        await cdp_a.evaluate(
            "(() => {"
            "  const _p = app.plugins.plugins['engram-vault-sync'];"
            "  if (window.__e2e_pushAll_orig) {"
            "    _p.syncEngine.pushAll = window.__e2e_pushAll_orig;"
            "  }"
            "  delete window.__e2e_pushAll_count;"
            "  delete window.__e2e_pushAll_orig;"
            "})()"
        )


# ---------------------------------------------------------------------------
# test_pull_all_invokes_handler
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_pull_all_invokes_handler(cdp_a):
    """pull-all: pullAll() on SyncEngine is called at least once."""
    # Install spy — capture original so we can restore exactly.
    # IIFE wrap avoids `const` leaks in the shared renderer execution context.
    await cdp_a.evaluate(
        "(() => {"
        "  window.__e2e_pullAll_count = 0;"
        "  const _p = app.plugins.plugins['engram-vault-sync'];"
        "  window.__e2e_pullAll_orig = _p.syncEngine.pullAll.bind(_p.syncEngine);"
        "  _p.syncEngine.pullAll = async (...a) => {"
        "    window.__e2e_pullAll_count++;"
        "    return window.__e2e_pullAll_orig(...a);"
        "  };"
        "})()"
    )
    try:
        await cdp_a.run_command("pull-all")
        called = 0
        for _ in range(20):
            called = await cdp_a.evaluate("window.__e2e_pullAll_count")
            if called >= 1:
                break
            await asyncio.sleep(0.25)
        assert called >= 1, f"pullAll was not called (count={called})"
    finally:
        await cdp_a.evaluate(
            "(() => {"
            "  const _p = app.plugins.plugins['engram-vault-sync'];"
            "  if (window.__e2e_pullAll_orig) {"
            "    _p.syncEngine.pullAll = window.__e2e_pullAll_orig;"
            "  }"
            "  delete window.__e2e_pullAll_count;"
            "  delete window.__e2e_pullAll_orig;"
            "})()"
        )

# ---------------------------------------------------------------------------
# test_show_sync_log_mounts
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_show_sync_log_mounts(cdp_a):
    """show-sync-log: .engram-sync-log-modal appears in the DOM."""
    try:
        await cdp_a.run_command("show-sync-log")
        # Modal renders synchronously but give a small grace period
        mounted = False
        for _ in range(20):
            mounted = await cdp_a.evaluate(
                "Boolean(document.querySelector('.engram-sync-log-modal'))"
            )
            if mounted:
                break
            await asyncio.sleep(0.1)
        assert mounted, ".engram-sync-log-modal did not mount after show-sync-log"
    finally:
        # Dismiss any open modals so they don't bleed into subsequent tests
        await cdp_a.evaluate(
            "document.querySelectorAll('.modal-container .modal').forEach("
            "  m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "    {key: 'Escape', bubbles: true}))"
            ")"
        )
