"""Test 65: Problem-dir scanner detects node_modules and offers ignore.

User path covered:
  User has node_modules/ in their vault → opens Settings → Advanced tab →
  plugin renders a warning row for the detected directory → user clicks
  "Add to ignores" → the pattern is appended to settings.ignorePatterns.

Implementation pivot (vs plan draft):
  The plan assumed plugin.scanProblemDirs() and plugin.addProblemDirToIgnores()
  exist as public methods.  They do NOT — the scan is performed inline inside
  renderIgnoreWarnings() (src/tabs/advanced-tab.ts), which runs automatically
  each time the Advanced tab is rendered via Obsidian's Setting display()
  lifecycle.  There is no standalone method to call.

  This test therefore drives the feature through the real settings UI:
    1. Create node_modules/junk/a.md in the vault (Vault.getAbstractFileByPath
       will see it after the next vault index tick).
    2. Open Obsidian settings and navigate to the plugin's Advanced tab by
       clicking the tab button whose data-tab="advanced" attribute matches.
    3. Wait for .engram-status-warning to appear (the warning row rendered by
       renderIgnoreWarnings when it detects node_modules/).
    4. Click the "Add to ignores" button inside the warning row.
    5. Assert settings.ignorePatterns now contains "node_modules/".
    6. Restore settings and delete the seeded directory in the finally block.

  We open the real Obsidian Settings modal (not a detached DOM render) because
  renderIgnoreWarnings() calls app.vault.getFolderByPath() — it needs the live
  vault object with a mounted tab context.  A headless evaluate() call to the
  render function would lack the TabContext.redisplay callback and the real
  plugin/app references wired by settings.ts.

CSS class verification (src/tabs/advanced-tab.ts):
  - Warning Setting rows are tagged with .engram-status-warning (line 150).
  - The "Add to ignores" button text is hard-coded as "Add to ignores" (line 140).
  - Our settings tab root is .engram-tab-content, in the main window on
    Obsidian 1.12 (Settings is a modal) and in a separate window on 1.13+.
    Reads go through cdp.settings_evaluate, which finds whichever it is.
  - Plugin tab panel is opened via app.setting.openTabById('engram-vault-sync').
  - Advanced tab button has data-tab="advanced" (settings.ts line 113).
"""

from __future__ import annotations

import asyncio
import shutil

import pytest


PLUGIN_ID = "engram-vault-sync"


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_node_modules_detected_and_addable(vault_a, cdp_a):
    """Advanced tab warning row appears for node_modules/ and "Add to ignores" works."""
    nm_dir = vault_a / "node_modules" / "junk"
    nm_dir.mkdir(parents=True, exist_ok=True)
    (nm_dir / "a.md").write_text("noise")

    original_patterns = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.ignorePatterns"
    )
    # Ensure node_modules/ is NOT already in patterns so the scanner shows the warning.
    if original_patterns and "node_modules/" in original_patterns:
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.ignorePatterns = {(original_patterns.replace('node_modules/', '')).strip()!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )

    # Wait for Obsidian's vault index to pick up the externally-seeded
    # node_modules/ folder BEFORE opening the Advanced tab. The scanner runs
    # exactly ONCE, synchronously, at tab render (renderIgnoreWarnings calls
    # app.vault.getFolderByPath) and never re-scans — so if the folder is not
    # in the vault cache at render time, the warning row can NEVER appear no
    # matter how long the DOM is polled afterwards. That is why bumping the
    # DOM wait 5s -> 20s did not help (run 28919928915 failed the 20s window
    # too): the failure is state-at-render-time, not render latency. Under
    # full-suite CI load the inotify -> vault-index tick for an external
    # mkdir can lag well past the moment we open the tab.
    indexed = False
    deadline = asyncio.get_event_loop().time() + 30
    while asyncio.get_event_loop().time() < deadline:
        indexed = await cdp_a.evaluate(
            "Boolean(app.vault.getFolderByPath('node_modules'))"
        )
        if indexed:
            break
        await asyncio.sleep(0.2)
    assert indexed, (
        "Obsidian's vault index never picked up the externally-seeded "
        "node_modules/ folder within 30 s — the scanner's precondition "
        "failed, not the warning-row render. Check the vault file watcher "
        "(inotify) in this environment before suspecting "
        "renderIgnoreWarnings()."
    )

    try:
        # Open the Obsidian settings modal and navigate to the plugin + Advanced tab.
        await cdp_a.evaluate(
            f"""
            (() => {{
                app.setting.open();
                app.setting.openTabById('{PLUGIN_ID}');
            }})()
            """
        )
        # Wait for OUR settings tab to render. Deliberately not
        # `.modal-container .modal.mod-settings`: that is 1.12-only markup.
        # Obsidian 1.13 opens Settings in a separate window where it is not a
        # modal at all, so the old selector could never match and the failure
        # blamed the plugin's tab registry for an Obsidian version bump.
        # `.engram-tab-content` is what settings.ts creates either way.
        settings_open = False
        for _ in range(30):  # 3 s
            tab_rendered = await cdp_a.settings_evaluate(
                "Boolean(document.querySelector('.engram-tab-content'))"
            )
            if tab_rendered:
                settings_open = True
                break
            await asyncio.sleep(0.1)
        assert settings_open, (
            "The plugin's settings tab (.engram-tab-content) did not render "
            "within 3 s. app.setting.open() + openTabById() should be "
            "synchronous; if it is missing, Obsidian's setting registry may "
            "have stopped accepting the engram tab id."
        )

        # Click the Advanced tab button (data-tab="advanced").
        clicked_tab = await cdp_a.settings_evaluate(
            """
            (() => {
                // Unscoped: `settings_evaluate` already targets the window
                // rendering our tab, and the `.modal.mod-settings` wrapper
                // does not exist when Settings is its own window (1.13+).
                const btn = document.querySelector('[data-tab="advanced"]');
                if (!btn) return 'no-tab-btn';
                btn.click();
                return 'clicked';
            })()
            """
        )
        assert clicked_tab == "clicked", (
            f"Advanced tab button not found — "
            f"data-tab='advanced' may not exist in this build. Got: {clicked_tab!r}"
        )

        # Wait for the .engram-status-warning row to appear
        # (renderIgnoreWarnings detects the vault folder and renders the
        # warning on tab render). The scanner is synchronous render, but
        # under full-suite CI load the render tick itself can be delayed —
        # 5 s flaked intermittently (passed in the previous run). Widened
        # to 20 s; this is still a poll, not a retry-with-redisplay (those
        # masked real regressions previously).
        warning_visible = False
        deadline = asyncio.get_event_loop().time() + 20
        while asyncio.get_event_loop().time() < deadline:
            warning_visible = await cdp_a.settings_evaluate(
                "Boolean(document.querySelector('.engram-status-warning'))"
            )
            if warning_visible:
                break
            await asyncio.sleep(0.2)
        assert warning_visible, (
            "node_modules/ warning row (.engram-status-warning) did not "
            "appear within 20 s of opening the Advanced tab. Either the "
            "problem-dir scanner stopped detecting node_modules/, or "
            "renderIgnoreWarnings no longer emits .engram-status-warning. "
            "Inspect settings.ts renderIgnoreWarnings() against current source."
        )

        # Click "Add to ignores" inside the warning row for node_modules/.
        clicked_btn = await cdp_a.settings_evaluate(
            """
            (() => {
                const warnings = Array.from(
                    document.querySelectorAll('.engram-status-warning')
                );
                // Find the row mentioning node_modules.
                const row = warnings.find(
                    w => w.textContent.includes('node_modules')
                );
                if (!row) return 'no-node-modules-row';
                const btn = Array.from(row.querySelectorAll('button')).find(
                    b => b.textContent.trim() === 'Add to ignores'
                );
                if (!btn) return 'no-add-btn';
                btn.click();
                return 'clicked';
            })()
            """
        )
        assert clicked_btn == "clicked", (
            f"'Add to ignores' button not found in node_modules warning row. "
            f"Got: {clicked_btn!r}"
        )

        # Allow the async saveSettings() to complete.
        await asyncio.sleep(0.5)

        # Assert the pattern was appended to settings.ignorePatterns.
        patterns = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].settings.ignorePatterns"
        )
        assert "node_modules/" in (patterns or ""), (
            f"Expected 'node_modules/' in ignorePatterns after clicking "
            f"'Add to ignores', got {patterns!r}"
        )

    finally:
        # `app.setting.close()`, not an Escape dispatched at `.modal-container`
        # in the main window: on Obsidian 1.13 Settings is a separate Electron
        # window that the main window's DOM cannot reach, so the old teardown
        # silently left it open for every later test in the session.
        await cdp_a.close_settings()
        # Restore settings.ignorePatterns to its original value.
        restore = original_patterns if isinstance(original_patterns, str) else ""
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.ignorePatterns = {restore!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        # Remove the seeded directory.
        shutil.rmtree(vault_a / "node_modules", ignore_errors=True)
