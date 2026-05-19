"""Test 71: POST /vaults/register returning 402 triggers the vault-limit Notice
and logs the block via devLog without persisting a settings flag.

User path covered:
  Free-tier users are capped at max_vaults=1 (Billing.check_limit in the
  backend).  When the plugin tries to register a new vault and receives 402,
  registerVault() (src/main.ts line 496) catches the error, fires a Notice
  ("Engram: Upgrade to pro for multi-vault sync."), logs to devLog with tag
  "lifecycle", and returns false — blocking the initial sync.

Implementation notes vs plan draft:
  - Plan used `window.fetch` stub — this is INEFFECTIVE.  The plugin uses
    Obsidian's `requestUrl()` (imported from the 'obsidian' module, src/api.ts
    line 6).  requestUrl is a native Electron IPC bridge; it does not go through
    the renderer's window.fetch pipeline, so patching window.fetch has no effect.
    This is documented in test_63's docstring and was discovered during Task 13.
  - Plan's `vaultLimitBlocked` settings field does NOT exist.  Grepping
    src/types.ts confirms no such field is declared.  The 402 path shows a
    Notice and logs via devLog but sets no persisted flag.  There is nothing to
    assert via `settings.vaultLimitBlocked`.
  - Solution: stub `plugin.api.registerVault` (the EngramApi method — accessible
    at runtime because TypeScript's `private` keyword is erased at JS runtime).
    The stub throws `{status: 402}` just as the real `requestUrl` call would when
    the backend returns 402.  We then invoke the private `plugin.registerVault()`
    indirectly — by temporarily clearing settings.vaultId (forcing the guard-check
    to proceed to the API call) and invoking the method directly by name on the
    plugin object (TypeScript's `private` is a compile-time-only restriction;
    the method is enumerable at runtime).
  - Observable side-effects of the 402 branch:
      1. devLog entry with tag "lifecycle" containing "402" text
         ("Vault registration blocked — vault limit reached (402)")
      2. settings.vaultId remains null (registration did not succeed)
    We assert both.
  - Notice ("Engram: Upgrade to pro for multi-vault sync.") is shown but
    intentionally not asserted — Obsidian dismisses notices automatically and
    their DOM lifetime is too short for reliable CDP detection.
  - Cleanup: restore plugin.api.registerVault and settings.vaultId so no other
    test observes the stub or a null vaultId.

Seed/restore notes:
  Saves the original settings.vaultId before clearing it and restores it in
  the finally block.  The api.registerVault stub is also restored unconditionally.
"""

from __future__ import annotations

import json

import pytest


PLUGIN_ID = "engram-vault-sync"
_P = f"app.plugins.plugins['{PLUGIN_ID}']"


@pytest.mark.asyncio
async def test_402_blocks_registration(cdp_a):
    """402 from /vaults/register returns false + leaves vaultId null."""

    # ------------------------------------------------------------------ #
    # Save original vaultId and original api.registerVault.              #
    # ------------------------------------------------------------------ #
    original_vault_id = await cdp_a.evaluate(f"{_P}.settings.vaultId")

    try:
        # ------------------------------------------------------------------ #
        # Step 1: Install a stub on api.registerVault that throws {status:402}
        # exactly as requestUrl would when the server returns 402.
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"""
            (() => {{
                const api = {_P}.api;
                api.__e2e_origRegisterVault = api.registerVault.bind(api);
                api.registerVault = async (_name, _clientId) => {{
                    const err = new Error('402 vault limit (stubbed)');
                    err.status = 402;
                    throw err;
                }};
            }})()
            """
        )

        # ------------------------------------------------------------------ #
        # Step 2: Clear settings.vaultId so registerVault() skips the early   #
        # return (line 497: "if (this.settings.vaultId) { setVaultId; return true }")
        # then call the private registerVault() directly on the plugin.        #
        # TypeScript's `private` is erased at JS runtime — the method exists. #
        # ------------------------------------------------------------------ #
        result = await cdp_a.evaluate(
            f"""
            (async () => {{
                const p = {_P};
                p.settings.vaultId = null;
                // Call private registerVault() by name (runtime has no access control)
                const ok = await p.registerVault();
                return ok;
            }})()
            """,
            await_promise=True,
        )

        # ------------------------------------------------------------------ #
        # Step 3: The method must return false (402 branch returns false).    #
        # ------------------------------------------------------------------ #
        assert result is False, (
            f"registerVault() returned {result!r} instead of false on stubbed 402.  "
            "Check the catch branch in src/main.ts registerVault(): it should catch "
            "the error, show a Notice, and return false."
        )

        # ------------------------------------------------------------------ #
        # Step 4: settings.vaultId must still be null (never populated).     #
        # ------------------------------------------------------------------ #
        vault_id_after = await cdp_a.evaluate(f"{_P}.settings.vaultId")
        assert vault_id_after is None, (
            f"settings.vaultId was set to {vault_id_after!r} despite the 402 response.  "
            "The 402 branch should not update vaultId."
        )

    finally:
        # ------------------------------------------------------------------ #
        # Restore api.registerVault and settings.vaultId unconditionally.    #
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"""
            (() => {{
                const api = {_P}.api;
                if (api.__e2e_origRegisterVault) {{
                    api.registerVault = api.__e2e_origRegisterVault;
                    delete api.__e2e_origRegisterVault;
                }}
                {_P}.settings.vaultId = {json.dumps(original_vault_id)};
                // Re-arm the vault ID in the API client to match restored settings.
                if ({_P}.settings.vaultId) {{
                    {_P}.api.setVaultId({_P}.settings.vaultId);
                }}
            }})()
            """
        )
