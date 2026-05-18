"""Test 64: Settings persistence across plugin reload.

User paths covered:
  1. conflictResolution dropdown change → reload → value persists.
  2. debounceMs text field change → reload → value persists.
  3. ignorePatterns textarea change → reload → value persists AND
     syncEngine.shouldIgnore() honours the new pattern.

Seed/restore strategy:
  Each test mutates exactly one setting, reloads the plugin, asserts, then
  restores the original value in a finally block.  reload_plugin() does a
  real disable/enable cycle (same as user toggling the plugin off and on),
  which exercises the full settings-load path.

Implementation notes:
  - ignorePatterns is stored as a newline-delimited *string*, not an array
    (see src/types.ts).  The plan draft used an array — corrected here.
  - The plan draft referenced settings.remoteLogging which does not exist;
    the real field is settings.remoteLoggingEnabled.  Not tested here since
    Task 16 covers that toggle.
  - shouldIgnore() lives on syncEngine (not directly on the plugin).
  - After reload the plugin re-parses the ignorePatterns string into its
    internal ignore list, so shouldIgnore() reflects the persisted value
    without any extra trigger.
"""

from __future__ import annotations

import pytest


PLUGIN_ID = "engram-vault-sync"


# ---------------------------------------------------------------------------
# Test 1: conflictResolution persists
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_conflict_mode_persists(cdp_a):
    """conflictResolution 'modal' survives plugin reload."""
    original = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.conflictResolution"
    )
    try:
        await cdp_a.set_conflict_resolution("modal")
        await cdp_a.reload_plugin()
        mode = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].settings.conflictResolution"
        )
        assert mode == "modal", f"Expected 'modal', got {mode!r}"
    finally:
        await cdp_a.set_conflict_resolution(original or "auto")
        # Save the restored value so a subsequent reload would also see it.
        await cdp_a.evaluate(
            f"(async () => {{ await app.plugins.plugins['{PLUGIN_ID}']"
            f".saveSettings(); }})()",
            await_promise=True,
        )


# ---------------------------------------------------------------------------
# Test 2: debounceMs persists
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_debounce_value_persists(cdp_a):
    """debounceMs 4321 survives plugin reload."""
    original = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.debounceMs"
    )
    try:
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.debounceMs = 4321;"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        await cdp_a.reload_plugin()
        val = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].settings.debounceMs"
        )
        assert val == 4321, f"Expected 4321, got {val!r}"
    finally:
        restore_val = original if isinstance(original, int) else 2000
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.debounceMs = {restore_val};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )


# ---------------------------------------------------------------------------
# Test 3: ignorePatterns persists + shouldIgnore honours it
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_custom_ignore_patterns_persist_and_apply(cdp_a):
    """ignorePatterns string persists across reload; shouldIgnore() honours it.

    ignorePatterns is a newline-delimited string (src/types.ts line 8).
    After reload the engine re-parses the string so shouldIgnore() reflects
    the saved value immediately.
    """
    original = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.ignorePatterns"
    )
    try:
        # Append a unique pattern to whatever is already configured.
        new_pattern = "scratch/"
        new_value = (
            f"{original}\n{new_pattern}".strip() if original else new_pattern
        )
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.ignorePatterns = {new_value!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        await cdp_a.reload_plugin()

        # Assert the string persisted.
        stored = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].settings.ignorePatterns"
        )
        assert new_pattern in (stored or ""), (
            f"Expected pattern {new_pattern!r} in stored ignorePatterns, got {stored!r}"
        )

        # Assert shouldIgnore() honours the new pattern.
        ignored = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].syncEngine"
            f".shouldIgnore('scratch/notes.md')"
        )
        assert ignored is True, (
            f"shouldIgnore('scratch/notes.md') should be True after adding "
            f"'{new_pattern}', got {ignored!r}"
        )
    finally:
        restore_val = original if isinstance(original, str) else ""
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.ignorePatterns = {restore_val!r};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
