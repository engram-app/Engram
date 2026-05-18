"""Test 64: Settings persistence (disk round-trip + one full reload smoke).

User paths covered:
  1. conflictResolution dropdown change → reload → value persists.
     (Full disable/enable cycle — smoke test for the re-init path.)
  2. debounceMs text field change → loadData() round-trip persists.
  3. ignorePatterns textarea change → loadData() round-trip persists AND
     syncEngine.shouldIgnore() honours the new pattern (the engine reads
     the in-memory settings string, which saveSettings already updates).

Why only one full reload:
  A full plugin reload (disable + enable + re-register vault + re-open
  WebSocket + possible startup fullSync) costs ~10s per test.  The
  saveSettings → loadData round-trip verifies the exact same surface
  (settings serialise to disk and deserialise back) without the noise.
  We keep one disable/enable cycle on the most user-facing setting
  (conflictResolution) as a smoke test for the full re-init path.

Implementation notes:
  - ignorePatterns is stored as a newline-delimited *string*, not an array
    (see src/types.ts).
  - The plan draft referenced settings.remoteLogging which does not exist;
    the real field is settings.remoteLoggingEnabled.  Not tested here since
    Task 16 covers that toggle.
  - shouldIgnore() lives on syncEngine (not directly on the plugin).
  - saveSettings() re-parses the ignorePatterns string into the engine's
    internal ignore list synchronously, so shouldIgnore() reflects the
    saved value immediately — no reload required.
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
    """debounceMs 4321 round-trips through loadData() — covers disk persistence.

    Skips the full plugin reload (which is exercised by
    test_conflict_mode_persists as the smoke test); a loadData() call
    proves saveSettings actually wrote to disk and the value is
    re-readable.
    """
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
        # Round-trip through loadData() — proves the value was actually
        # serialised to disk and is re-readable, without the cost of a
        # full plugin reload.
        on_disk = await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  const data = await p.loadData();"
            f"  return data && data.debounceMs;"
            f"}})()",
            await_promise=True,
        )
        assert on_disk == 4321, (
            f"Expected debounceMs=4321 on disk after saveSettings(), got {on_disk!r}"
        )
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
    """ignorePatterns string round-trips through loadData(); shouldIgnore() honours it.

    ignorePatterns is a newline-delimited string (src/types.ts line 8).
    saveSettings() updates the engine's parsed ignore list synchronously,
    so shouldIgnore() reflects the new value without a reload.  A
    loadData() round-trip then proves the string was actually written
    to disk — same persistence guarantee as a full reload, without the
    ~10s reload cost.
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

        # Round-trip through loadData() — proves the new pattern was
        # actually written to disk, equivalent persistence guarantee to
        # a full plugin reload.
        on_disk = await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  const data = await p.loadData();"
            f"  return (data && data.ignorePatterns) || '';"
            f"}})()",
            await_promise=True,
        )
        assert new_pattern in (on_disk or ""), (
            f"Expected pattern {new_pattern!r} in on-disk ignorePatterns, got {on_disk!r}"
        )

        # Assert shouldIgnore() honours the new pattern. saveSettings()
        # re-parses the ignorePatterns string into the engine's internal
        # list synchronously, so this works without any reload.
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
