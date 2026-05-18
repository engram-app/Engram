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
  - The Settings modal root is .modal-container .modal.mod-settings.
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
        # Wait for the settings modal to appear. app.setting.open() and
        # openTabById() are synchronous in Obsidian — a 3 s ceiling is
        # already 30× the typical render time.
        settings_open = False
        for _ in range(30):  # 3 s
            modal_open = await cdp_a.evaluate(
                "Boolean(document.querySelector('.modal-container .modal.mod-settings'))"
            )
            if modal_open:
                settings_open = True
                break
            await asyncio.sleep(0.1)
        assert settings_open, (
            "Obsidian settings modal did not open within 3 s. "
            "app.setting.open() + openTabById() should be synchronous; "
            "if the modal is missing, Obsidian's setting registry may have "
            "stopped accepting the engram tab id."
        )

        # Click the Advanced tab button (data-tab="advanced").
        clicked_tab = await cdp_a.evaluate(
            """
            (() => {
                const btn = document.querySelector(
                    '.modal-container .modal.mod-settings [data-tab="advanced"]'
                );
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
        # warning on tab render). The scanner is synchronous render — if
        # it didn't fire within 5 s it's broken. No redisplay retries:
        # those masked real regressions previously.
        warning_visible = False
        deadline = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline:
            warning_visible = await cdp_a.evaluate(
                "Boolean(document.querySelector('.engram-status-warning'))"
            )
            if warning_visible:
                break
            await asyncio.sleep(0.2)
        assert warning_visible, (
            "node_modules/ warning row (.engram-status-warning) did not "
            "appear within 5 s of opening the Advanced tab. Either the "
            "problem-dir scanner stopped detecting node_modules/, or "
            "renderIgnoreWarnings no longer emits .engram-status-warning. "
            "Inspect settings.ts renderIgnoreWarnings() against current source."
        )

        # Click "Add to ignores" inside the warning row for node_modules/.
        clicked_btn = await cdp_a.evaluate(
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
        # Close the settings modal.
        await cdp_a.evaluate(
            """
            document.querySelectorAll('.modal-container .modal').forEach(
                m => m.dispatchEvent(
                    new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})
                )
            )
            """
        )
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
