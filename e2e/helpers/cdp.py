"""CDP (Chrome DevTools Protocol) client for interacting with Obsidian runtime."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import requests
import websockets

logger = logging.getLogger(__name__)

PLUGIN_ID = "engram-vault-sync"
PLUGIN_PATH = f"app.plugins.plugins['{PLUGIN_ID}']"
ENGINE_PATH = f"{PLUGIN_PATH}.syncEngine"


class CdpError(Exception):
    pass


class CdpClient:
    def __init__(self, port: int = 9222, host: str = "127.0.0.1"):
        self.port = port
        self.host = host
        self._base_url = f"http://{host}:{port}"
        self._ws = None
        self._msg_id = 0

    def _get_ws_url(self) -> str:
        resp = requests.get(f"{self._base_url}/json", timeout=5)
        resp.raise_for_status()
        pages = resp.json()
        if not pages:
            raise CdpError("No CDP pages available")
        return pages[0]["webSocketDebuggerUrl"]

    async def _ensure_connected(self) -> None:
        """Ensure WebSocket is connected, reconnect if stale."""
        if self._ws is not None:
            try:
                pong = await self._ws.ping()
                await asyncio.wait_for(pong, timeout=2)
                return
            except Exception:
                await self._close()

        ws_url = self._get_ws_url()
        self._ws = await websockets.connect(ws_url)

    async def _close(self) -> None:
        """Close WebSocket if open."""
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    async def evaluate(self, expr: str, await_promise: bool = False) -> Any:
        """Evaluate JS expression in Obsidian's renderer process.

        Uses a persistent WebSocket connection, reconnecting on failure.
        """
        self._msg_id += 1
        msg_id = self._msg_id

        async def _send_recv() -> Any:
            msg = {
                "id": msg_id,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": expr,
                    "returnByValue": True,
                    "awaitPromise": await_promise,
                },
            }
            await self._ws.send(json.dumps(msg))
            resp = json.loads(await self._ws.recv())

            if "error" in resp:
                raise CdpError(f"CDP error: {resp['error']}")

            result = resp.get("result", {}).get("result", {})
            if result.get("type") == "undefined":
                return None
            if "value" in result:
                return result["value"]
            if result.get("subtype") == "error":
                raise CdpError(f"JS error: {result.get('description', result)}")
            return result

        await self._ensure_connected()
        try:
            return await _send_recv()
        except CdpError:
            raise
        except Exception:
            # Reconnect once and retry on connection-level failures
            await self._close()
            await self._ensure_connected()
            return await _send_recv()

    async def wait_for_plugin_ready(self, timeout: float = 30) -> None:
        """Poll until the engram-vault-sync plugin's SyncEngine reports ready."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                ready = await self.evaluate(f"{ENGINE_PATH}.ready")
                if ready is True:
                    logger.info("Plugin ready on CDP port %d", self.port)
                    return
            except Exception:
                pass
            await asyncio.sleep(1)
        raise TimeoutError(
            f"Plugin not ready after {timeout}s on CDP port {self.port}"
        )

    async def wait_for_vault_registered(self, timeout: float = 15) -> None:
        """Ensure plugin.settings.vaultId is populated, triggering re-register if not.

        After plugin.onload registers the vault via /vaults/register the engine
        has a vaultId — required for computeSyncFingerprint, which
        markSyncGateAccepted depends on. Mid-suite the vaultId can be cleared
        by the channel's ``onVaultDeleted`` handler (src/main.ts ~line 680),
        and nothing in the plugin actively re-registers until the next
        ``saveSettings`` fires. Passive polling never recovers from that
        state, so this helper actively calls ``plugin.registerVault()``
        (private at compile time, public at runtime) when vaultId is null,
        then polls for the result. Idempotent — the plugin's own guard at
        registerVault() line 497 short-circuits when vaultId is already set.

        Captures the registerVault result (true/false/error reason) into the
        TimeoutError so a failed registration surfaces the *cause* (402,
        network failure, etc.) instead of just "Vault not registered after
        15s" — silent registerVault failures used to repro as a passive
        timeout with no signal of what went wrong.
        """
        deadline = time.monotonic() + timeout
        triggered = False
        diag: dict = {}
        while time.monotonic() < deadline:
            try:
                vault_id = await self.evaluate(
                    f"{PLUGIN_PATH}.settings && {PLUGIN_PATH}.settings.vaultId"
                )
                if vault_id:
                    logger.info(
                        "Vault registered on CDP port %d: %s", self.port, vault_id
                    )
                    return
                if not triggered:
                    triggered = True
                    # ── Snapshot plugin auth state ──────────────────────────
                    # apiKey/refreshToken length + prefix tells us if the
                    # field is empty (cleared by a failed restore) vs present
                    # but rejected by backend.
                    diag["plugin_state"] = await self.evaluate(
                        f"""
                        (() => {{
                            const s = {PLUGIN_PATH}.settings || {{}};
                            const p = {PLUGIN_PATH};
                            const k = s.apiKey || '';
                            const r = s.refreshToken || '';
                            return {{
                                apiKeyLen: k.length,
                                apiKeyPrefix: k.slice(0, 8),
                                refreshTokenLen: r.length,
                                refreshTokenPrefix: r.slice(0, 12),
                                authMethod: s.authMethod || null,
                                clientId: s.clientId || null,
                                vaultId: s.vaultId || null,
                                authProviderType:
                                    p.authProvider?.constructor?.name || null,
                            }};
                        }})()
                        """
                    )
                    # ── On-disk state ──────────────────────────────────────
                    # If memory says apiKeyLen=0 but disk says apiKey is
                    # present, a stale plugin instance is reading wiped
                    # state. If both empty, something actively wiped disk.
                    # Distinguishes "plugin reload lost it" from "state
                    # actively cleared" — critical for tracing apiKey-wipe
                    # flakes across the test sequence.
                    diag["disk_state"] = await self.evaluate(
                        f"""
                        (async () => {{
                            try {{
                                const data = await {PLUGIN_PATH}.loadData() || {{}};
                                const ds = data.settings || {{}};
                                const k = ds.apiKey || '';
                                const r = ds.refreshToken || '';
                                return {{
                                    diskApiKeyLen: k.length,
                                    diskApiKeyPrefix: k.slice(0, 8),
                                    diskRefreshTokenLen: r.length,
                                    diskAuthMethod: ds.authMethod || null,
                                    diskVaultId: ds.vaultId || null,
                                    diskClientId: ds.clientId || null,
                                    diskKeysPresent: Object.keys(ds).sort(),
                                    syncGateAcceptedFor:
                                        data.syncGateAcceptedFor || null,
                                }};
                            }} catch (e) {{
                                return {{ error: String(e?.message || e) }};
                            }}
                        }})()
                        """,
                        await_promise=True,
                    )
                    # ── Backend reachability (no-auth) ──────────────────────
                    diag["health"] = await self.evaluate(
                        f"{PLUGIN_PATH}.api.health()"
                        f".then(r => ['ok', r])"
                        f".catch(e => ['err', String(e?.message || e), e?.status ?? null])",
                        await_promise=True,
                    )
                    # ── /me with current auth (identifies user_id + scope) ──
                    diag["me"] = await self.evaluate(
                        f"{PLUGIN_PATH}.api.getMe()"
                        f".then(u => ['ok', u])"
                        f".catch(e => ['err', String(e?.message || e), e?.status ?? null])",
                        await_promise=True,
                    )
                    # ── plugin.registerVault (production wrapper) ──────────
                    diag["plugin_registerVault"] = await self.evaluate(
                        f"{PLUGIN_PATH}.registerVault()"
                        f".then(r => ['ok', r])"
                        f".catch(e => ['err', String(e?.message || e), e?.status ?? null])",
                        await_promise=True,
                    )
                    # ── api.registerVault DIRECT (HTTP status preserved) ───
                    diag["api_registerVault"] = await self.evaluate(
                        f"{PLUGIN_PATH}.api.registerVault("
                        f"app.vault.getName(), {PLUGIN_PATH}.settings.clientId)"
                        f".then(r => ['ok', r])"
                        f".catch(e => ['err', String(e?.message || e), e?.status ?? null])",
                        await_promise=True,
                    )
                    # ── listVaults inventory ───────────────────────────────
                    diag["listVaults"] = await self.evaluate(
                        f"{PLUGIN_PATH}.api.listVaults()"
                        f".then(vs => ['ok', vs.length, vs.map(v => "
                        f"({{id: v.id, client_id: v.client_id, name: v.name}}))])"
                        f".catch(e => ['err', String(e?.message || e), e?.status ?? null])",
                        await_promise=True,
                    )
                    logger.info("vault-registration diagnostic on port %d: %r",
                                self.port, diag)
                    continue
            except Exception:
                pass
            await asyncio.sleep(0.5)
        lines = [
            f"Vault not registered after {timeout}s on CDP port {self.port}",
        ]
        for k in (
            "plugin_state",
            "disk_state",
            "health",
            "me",
            "plugin_registerVault",
            "api_registerVault",
            "listVaults",
        ):
            lines.append(f"  {k:22s} → {diag.get(k)!r}")
        raise TimeoutError("\n".join(lines))

    async def has_sync_gate(self) -> bool:
        """True when the loaded plugin exposes the SyncPreviewModal gate API.

        Older plugin builds (pre-SyncPreviewModal) lack markSyncGateAccepted /
        setSyncBlocked entirely. The harness must stay backwards-compatible
        with whatever plugin SHA the cross-repo trigger ships, so every
        gate helper short-circuits when this returns False.
        """
        result = await self.evaluate(
            f"typeof {PLUGIN_PATH}.markSyncGateAccepted === 'function'"
        )
        return result is True

    async def accept_sync_gate(self) -> None:
        """Simulate the user accepting the sync-preview modal.

        Drives the same code path as a real click in SyncPreviewModal:
        markSyncGateAccepted() persists the fingerprint and flips
        syncBlocked=false; the open modal is then dismissed via Escape so
        the awaiting startup flow resolves with "cancel" (a no-op now that
        the gate has been accepted out-of-band).

        Idempotent — safe to call when no modal is open. No-op against
        plugin builds that predate the sync gate.
        """
        if not await self.has_sync_gate():
            logger.info("Sync gate not present on plugin; skipping accept")
            return
        # markSyncGateAccepted requires a vault to be registered (it hashes
        # apiKey + vaultId). Wait briefly so first-launch tests don't race
        # the plugin's startup register call.
        await self.wait_for_vault_registered()
        await self.evaluate(
            f"{PLUGIN_PATH}.markSyncGateAccepted().then(() => 'ok')",
            await_promise=True,
        )
        # Resolve any open modal — modals listen for Escape and resolve
        # their awaitChoice() promise with "cancel". With the gate already
        # accepted, runSyncFromChoice("cancel") is a no-op.
        await self.evaluate(
            """
            (() => {
                const modals = document.querySelectorAll('.modal-container .modal');
                for (const m of modals) {
                    m.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Escape', bubbles: true,
                    }));
                }
                return modals.length;
            })()
            """
        )
        logger.info("Sync gate accepted on CDP port %d", self.port)

    async def reset_sync_gate(self) -> None:
        """Put the engine back into gate-closed state (for modal-flow tests).

        Clears the saved fingerprint and re-blocks the engine so the next
        startup or saveSettings will reopen SyncPreviewModal. Mirrors the
        production "change vault" path which resets the gate to force a
        new direction choice. No-op against gate-less plugin builds.
        """
        if not await self.has_sync_gate():
            return
        await self.evaluate(
            f"""
            (() => {{
                const p = {PLUGIN_PATH};
                p.syncGateAcceptedFor = null;
                p.syncEngine.setSyncBlocked(true);
                return 'reset';
            }})()
            """
        )
        logger.info("Sync gate reset on CDP port %d", self.port)

    async def is_sync_blocked(self) -> bool:
        """Read the engine's syncBlocked flag. False when plugin lacks gate."""
        if not await self.has_sync_gate():
            return False
        return await self.evaluate(f"{ENGINE_PATH}.isSyncBlocked()") is True

    async def open_sync_preview_modal(self) -> None:
        """Fire SyncPreviewModal in the background (does not await user choice).

        Mirrors production calls into plugin.doSyncWithFirstSyncCheck.
        Returns immediately — the modal stays open until a button is
        clicked or the modal is dismissed.
        """
        # Note: NOT await_promise. The promise from doSyncWithFirstSyncCheck
        # only resolves once the user picks (or cancels). Returning early
        # lets the test poll DOM presence and then drive the interaction.
        await self.evaluate(
            f"void {PLUGIN_PATH}.doSyncWithFirstSyncCheck()"
        )

    async def wait_for_sync_preview_modal(self, timeout: float = 5) -> None:
        """Poll until SyncPreviewModal is mounted AND settled in the DOM.

        Mounted-only was racy: `Modal.onOpen()` resolves before the open CSS
        transition finishes, so a header read / option click could fire against
        an un-painted modal (issue #161). "Settled" means: present, the
        animating `.modal-container` ancestor has reached full opacity, and the
        element has layout boxes (actually rendered). Degrades to mounted-only
        when there's no transition (opacity is 1 immediately), so it never
        waits longer than necessary.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            settled = await self.evaluate(
                "(() => {"
                "  const el = document.querySelector('.engram-sync-preview-modal');"
                "  if (!el) return false;"
                "  const anim = el.closest('.modal-container') || el;"
                "  const op = parseFloat(getComputedStyle(anim).opacity || '1');"
                "  return op >= 0.99 && el.getClientRects().length > 0;"
                "})()"
            )
            if settled is True:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError(
            f"SyncPreviewModal not settled after {timeout}s on CDP port {self.port}"
        )

    async def dismiss_modals(
        self, max_attempts: int = 20, poll: float = 0.1
    ) -> None:
        """Dispatch Escape repeatedly until no modal remains in the DOM.

        Obsidian's stacked-modal views (e.g. SyncPreviewModal's destructive
        confirm view layered on top of the option-pick view) consume one
        Escape per layer — a single Escape collapses the confirm view back to
        the option-pick view but the outer modal stays mounted. Looping
        Escape-and-check is the deterministic dismiss: it bounds in
        ``max_attempts × poll`` wall time and exits the moment the DOM is
        actually empty, no animation guesswork needed.
        """
        for _ in range(max_attempts):
            present = await self.evaluate(
                "Boolean(document.querySelector('.modal-container .modal'))"
            )
            if present is False:
                return
            await self.evaluate(
                "document.querySelectorAll('.modal-container .modal').forEach("
                "m => m.dispatchEvent(new KeyboardEvent('keydown', "
                "{key: 'Escape', bubbles: true})))"
            )
            await asyncio.sleep(poll)
        raise TimeoutError(
            f"Modal still mounted after {max_attempts} Escape attempts "
            f"on CDP port {self.port}"
        )

    async def wait_for_modal_closed(self, timeout: float = 5) -> None:
        """Poll until SyncPreviewModal is gone from the DOM."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            present = await self.evaluate(
                "Boolean(document.querySelector('.engram-sync-preview-modal'))"
            )
            if present is False:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError(
            f"SyncPreviewModal still mounted after {timeout}s on CDP port {self.port}"
        )

    async def get_modal_header_text(self) -> str:
        """Read the first .engram-sync-preview-header text in the open modal."""
        result = await self.evaluate(
            """
            (() => {
                const h = document.querySelector(
                    '.engram-sync-preview-modal .engram-sync-preview-header'
                );
                return h ? h.textContent : '';
            })()
            """
        )
        return result or ""

    async def pick_modal_option(self, label: str, timeout: float = 10) -> None:
        """Click a SyncPreviewModal option button by its visible label.

        The option buttons render asynchronously (plugin #145): the modal
        opens in a loading view while computeSyncPlan runs in the background,
        and the merge/push/pull options only appear once the plan resolves
        (SyncPreviewModal.setPlan → render). Poll until the labelled option
        is present before clicking, rather than assuming it exists the instant
        the modal container mounts.

        For destructive choices the modal switches to the confirm view —
        call click_modal_confirm() afterward to resolve.
        """
        escaped = json.dumps(label)
        deadline = time.monotonic() + timeout
        while True:
            clicked = await self.evaluate(
                f"""
                (() => {{
                    const labels = document.querySelectorAll(
                        '.engram-sync-preview-modal .engram-sync-preview-option-label'
                    );
                    for (const span of labels) {{
                        if (span.textContent.trim() === {escaped}) {{
                            const btn = span.closest('button');
                            if (btn) {{
                                // The push/pull options moved behind an
                                // "Advanced sync options" <details> accordion
                                // (plugin #145). Open any ancestor <details>
                                // so the option is interactable before click.
                                const det = btn.closest('details');
                                if (det) det.open = true;
                                btn.click();
                                return true;
                            }}
                        }}
                    }}
                    return false;
                }})()
                """
            )
            if clicked is True:
                return
            if time.monotonic() >= deadline:
                raise CdpError(f"Modal option '{label}' not found")
            await asyncio.sleep(0.2)

    async def click_modal_confirm(self) -> None:
        """Type "delete" and click the confirm button for a destructive choice.

        SyncPreviewModal's confirm view requires the user to type "delete"
        before the confirm button enables (sync-preview-modal.ts
        renderConfirm). Drive both steps here so callers stay
        UX-independent.
        """
        clicked = await self.evaluate(
            """
            (() => {
                const input = document.querySelector(
                    '.engram-sync-preview-modal .engram-sync-preview-confirm-input'
                );
                const btn = document.querySelector(
                    '.engram-sync-preview-modal .engram-sync-preview-confirm-btn'
                );
                if (!input || !btn) return false;
                input.value = 'delete';
                input.dispatchEvent(new Event('input', { bubbles: true }));
                if (btn.disabled) return false;
                btn.click();
                return true;
            })()
            """
        )
        if clicked is not True:
            raise CdpError("Modal confirm button not present or still disabled")

    async def install_choice_spy(self, swallow: bool = False) -> None:
        """Wrap plugin.runSyncFromChoice so tests can read the resolved choice.

        When swallow=False the original method still runs (the spy is purely
        an observer). When swallow=True the spy records the choice and
        substitutes a no-op — useful for tests that want to verify modal
        dispatch without performing the underlying sync (which would push,
        pull, or delete real files).
        """
        swallow_js = "true" if swallow else "false"
        await self.evaluate(
            f"""
            (() => {{
                const p = {PLUGIN_PATH};
                if (p.__origRunSyncFromChoice) return 'already-installed';
                p.__origRunSyncFromChoice = p.runSyncFromChoice.bind(p);
                // runSyncWithProgress wraps runSyncFromChoice with a live
                // progress modal. Bypass it under the spy so the dispatch test
                // doesn't leave a (never-completing, swallowed) progress modal
                // mounted across parametrized runs.
                p.__origRunSyncWithProgress = p.runSyncWithProgress.bind(p);
                p.runSyncWithProgress = async (choice) => p.runSyncFromChoice(choice);
                p.__lastSyncChoice = null;
                const swallow = {swallow_js};
                p.runSyncFromChoice = async (choice) => {{
                    p.__lastSyncChoice = choice;
                    if (swallow) {{
                        // Mirror markSyncGateAccepted's side effect so the
                        // post-choice gate-state assertion remains valid.
                        if (choice !== 'cancel' && choice !== 'change-vault') {{
                            await p.markSyncGateAccepted();
                        }}
                        return choice !== 'cancel' && choice !== 'change-vault';
                    }}
                    return p.__origRunSyncFromChoice(choice);
                }};
                return 'installed';
            }})()
            """
        )

    async def uninstall_choice_spy(self) -> None:
        """Remove the spy installed by install_choice_spy()."""
        await self.evaluate(
            f"""
            (() => {{
                const p = {PLUGIN_PATH};
                if (!p.__origRunSyncFromChoice) return 'not-installed';
                p.runSyncFromChoice = p.__origRunSyncFromChoice;
                if (p.__origRunSyncWithProgress) {{
                    p.runSyncWithProgress = p.__origRunSyncWithProgress;
                    delete p.__origRunSyncWithProgress;
                }}
                delete p.__origRunSyncFromChoice;
                delete p.__lastSyncChoice;
                return 'removed';
            }})()
            """
        )

    async def get_last_sync_choice(self) -> str | None:
        """Read the choice recorded by install_choice_spy(), if any."""
        return await self.evaluate(f"{PLUGIN_PATH}.__lastSyncChoice")

    async def reload_plugin(self) -> None:
        """Disable and re-enable engram-vault-sync to simulate plugin reload."""
        await self.evaluate(
            'app.plugins.disablePlugin("engram-vault-sync").then(() => "off")',
            await_promise=True,
        )
        await self.evaluate(
            'app.plugins.enablePlugin("engram-vault-sync").then(() => "on")',
            await_promise=True,
        )
        await self.wait_for_plugin_ready(timeout=15)

    async def trigger_full_sync(self) -> dict:
        """Call syncEngine.fullSync() and return {pulled, pushed}."""
        result = await self.evaluate(
            f"{ENGINE_PATH}.fullSync().then(r => JSON.stringify(r))",
            await_promise=True,
        )
        if isinstance(result, str):
            return json.loads(result)
        return result or {}

    async def push_file_now(self, path: str, content: str) -> bool:
        """Deterministically seed a note: write via vault API, then await pushFile.

        Replaces the racy ``write_note + sleep + trigger_full_sync`` pattern.
        Steps performed inside the renderer (atomically from the test's POV):

          1. Accept the sync gate if it's closed — required for handleModify /
             pushFile to do real work.
          2. Use ``app.vault.create()`` so Obsidian's index sees the file
             immediately (raw filesystem writes don't show in ``getFiles()``
             until the watcher fires). If the file already exists, fall back
             to ``app.vault.modify()`` so the helper is idempotent.
          3. Call ``syncEngine.pushFile(file, true)`` directly — bypasses the
             handleModify debounce timer and returns a real promise we can
             await. The ``true`` argument forces the push (skips echo
             suppression for fresh files).

        Returns the resolved push result. Raises CdpError on push failure.
        """
        # Step 1: accept the gate so pushFile isn't short-circuited.
        await self.accept_sync_gate()

        escaped_path = json.dumps(path)
        escaped_content = json.dumps(content)
        result = await self.evaluate(
            f"""
            (async () => {{
                const p = {PLUGIN_PATH};
                const se = p.syncEngine;
                let file = app.vault.getFileByPath({escaped_path});
                if (file) {{
                    await app.vault.modify(file, {escaped_content});
                }} else {{
                    // Ensure parent folders exist (vault.create won't auto-mkdir).
                    const slash = {escaped_path}.lastIndexOf('/');
                    if (slash > 0) {{
                        const dir = {escaped_path}.slice(0, slash);
                        if (!app.vault.getAbstractFileByPath(dir)) {{
                            try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
                        }}
                    }}
                    file = await app.vault.create({escaped_path}, {escaped_content});
                }}
                // Cancel any pending debounce so we own the push deterministically.
                const pending = se.debounceTimers.get(file.path);
                if (pending) {{
                    clearTimeout(pending);
                    se.debounceTimers.delete(file.path);
                }}
                const ok = await se.pushFile(file, true);
                // pushFile() itself doesn't log success entries — pushAll does
                // (see sync.ts:2033). Mirror that here so tests that inspect
                // syncLog / activity log can find a 'push' entry for this path.
                try {{
                    p.syncLog?.append({{
                        timestamp: new Date(),
                        action: 'push',
                        path: file.path,
                        result: ok ? 'ok' : 'skipped',
                    }});
                }} catch (_) {{}}
                return ok;
            }})()
            """,
            await_promise=True,
        )
        return bool(result)

    async def trigger_pull(self) -> int:
        """Call syncEngine.pull() and return count of pulled notes."""
        result = await self.evaluate(
            f"{ENGINE_PATH}.pull().then(r => r)", await_promise=True
        )
        return result if isinstance(result, int) else 0

    async def get_sync_status(self) -> dict:
        """Read syncEngine.getStatus()."""
        result = await self.evaluate(
            f"JSON.stringify({ENGINE_PATH}.getStatus())"
        )
        if isinstance(result, str):
            return json.loads(result)
        return result or {}

    async def get_last_sync(self) -> str | None:
        """Read the lastSync timestamp string."""
        return await self.evaluate(f"{ENGINE_PATH}.lastSync")

    async def get_sync_cursor(self) -> str | None:
        """Read the opaque sync cursor (B2 ordered-pull watermark)."""
        return await self.evaluate(f"{ENGINE_PATH}.getSyncCursor()")

    async def accelerate_echo_expiry(self, path: str, ms: int = 200) -> None:
        """Replace the pending recentlyPushed timer for ``path`` with a short one.

        ``markRecentlyPushed`` arms a ``setTimeout(ECHO_COOLDOWN_MS=5000)`` to
        clear the entry. Tests that just want to drive the expiry branch should
        not sleep for the full production cooldown — shorten the timer so the
        same clear path runs in tens of ms.

        The timer-fires-and-clears mechanism is preserved (we install a real
        ``setTimeout``, not a synchronous ``delete``), so assertions on
        ``isRecentlyPushed`` going False still exercise the production code path.
        Raises CdpError when no timer is armed for ``path``.
        """
        escaped = json.dumps(path)
        result = await self.evaluate(
            f"""
            (() => {{
                const m = {ENGINE_PATH}.recentlyPushed;
                const t = m.get({escaped});
                if (t === undefined) return 'no-timer';
                window.clearTimeout(t);
                const newT = window.setTimeout(
                    () => m.delete({escaped}), {int(ms)}
                );
                m.set({escaped}, newT);
                return 'rearmed';
            }})()
            """
        )
        if result != "rearmed":
            raise CdpError(
                f"accelerate_echo_expiry: no recentlyPushed timer for {path!r}"
            )

    async def check_stream_connected(self) -> bool:
        """Check if the plugin's real-time stream (WebSocket channel) is connected."""
        result = await self.evaluate(f"{PLUGIN_PATH}.isLiveConnected()")
        return result is True

    async def _stream_diag(self) -> str:
        """Best-effort snapshot of the live channel's internal state.

        CI does not capture plugin-runtime logs, so a bare "Stream not
        connected" timeout gives no clue WHICH stuck state the channel was in.
        Read the observable channel fields (ws readyState, connected,
        crdtJoined, crdtJoinFailedReason, pending reconnect) so a recurrence is
        diagnosable from the assertion message alone.
        """
        try:
            raw = await self.evaluate(
                f"""
                (() => {{
                    const p = {PLUGIN_PATH};
                    const ns = p && p.noteStream;
                    if (!ns) return JSON.stringify({{error: 'no noteStream'}});
                    return JSON.stringify({{
                        isLiveConnected: typeof p.isLiveConnected === 'function' ? p.isLiveConnected() : null,
                        wsReadyState: ns.ws ? ns.ws.readyState : null,
                        connected: typeof ns.isConnected === 'function' ? ns.isConnected() : null,
                        crdtJoined: typeof ns.isCrdtConnected === 'function' ? ns.isCrdtConnected() : null,
                        crdtJoinFailedReason: ns.crdtJoinFailedReason ?? null,
                        reconnectPending: ns.reconnectTimer != null,
                        connId: typeof ns.getConnId === 'function' ? ns.getConnId() : null
                    }});
                }})()
                """
            )
            return raw if isinstance(raw, str) else json.dumps(raw)
        except Exception as e:  # noqa: BLE001
            # Instrumentation must never mask the TimeoutError it annotates: a
            # CDP evaluate can itself fail mid-teardown. Degrade to a reason
            # string; the real timeout is still raised by the caller.
            return f"<stream diag unavailable: {e!r}>"

    async def wait_for_stream_connected(self, timeout: float = 10) -> None:
        """Poll until the WebSocket channel reports connected.

        Use at the top of tests that rely on live propagation — the channel
        can take a beat to (re)connect after fixture setup or after a
        preceding test reset state.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if await self.check_stream_connected():
                return
            await asyncio.sleep(0.5)
        diag = await self._stream_diag()
        raise TimeoutError(
            f"Stream not connected after {timeout}s on CDP port {self.port} — channel={diag}"
        )


    async def set_conflict_resolution(self, mode: str) -> None:
        """Set the plugin's conflictResolution setting.

        Modes: 'auto' (creates conflict files) or 'modal' (calls onConflict handler).
        """
        js = f"{ENGINE_PATH}.settings.conflictResolution = '{mode}'"
        await self.evaluate(js)
        logger.info("Conflict resolution set to '%s' on CDP port %d", mode, self.port)

    async def override_conflict_handler(
        self, choice: str, merged_content: str | None = None
    ) -> None:
        """Override onConflict to auto-resolve with the given choice.

        Valid choices: 'keep-local', 'keep-remote', 'keep-both', 'skip', 'merge'
        """
        if merged_content is not None:
            escaped = json.dumps(merged_content)
            js = (
                f"{ENGINE_PATH}.onConflict = async (info) => "
                f"({{choice: '{choice}', mergedContent: {escaped}}})"
            )
        else:
            js = (
                f"{ENGINE_PATH}.onConflict = async (info) => "
                f"({{choice: '{choice}'}})"
            )
        await self.evaluate(js)
        logger.info("Conflict handler overridden to '%s'", choice)

    async def pause_outgoing_sync(self) -> None:
        """Block plugin from pushing changes by replacing handlers with no-ops.

        Saves originals so resume_outgoing_sync() can restore them.
        Also clears any pending debounce timers to prevent in-flight pushes.
        """
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            se._origHandleModify = se.handleModify.bind(se);
            se._origHandleDelete = se.handleDelete.bind(se);
            se._origHandleRename = se.handleRename.bind(se);
            se.handleModify = () => {{}};
            se.handleDelete = () => {{}};
            se.handleRename = () => {{}};
            // Clear pending debounce timers
            for (const [, timer] of se.debounceTimers) clearTimeout(timer);
            se.debounceTimers.clear();
            return 'paused';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Outgoing sync paused on CDP port %d: %s", self.port, result)

    async def resume_outgoing_sync(self) -> None:
        """Restore original push handlers saved by pause_outgoing_sync()."""
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            if (se._origHandleModify) se.handleModify = se._origHandleModify;
            if (se._origHandleDelete) se.handleDelete = se._origHandleDelete;
            if (se._origHandleRename) se.handleRename = se._origHandleRename;
            delete se._origHandleModify;
            delete se._origHandleDelete;
            delete se._origHandleRename;
            return 'resumed';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Outgoing sync resumed on CDP port %d: %s", self.port, result)

    async def vault_write(self, path: str, content: str) -> None:
        """Write a file via Obsidian's vault API so the index sees it synchronously.

        Plain filesystem writes (helpers.vault.write_note) are picked up only
        when Obsidian's file watcher fires — async, racy. Code paths that need
        the file to be in ``app.vault.getFiles()`` immediately (e.g. the
        ``setup_conflict_for_a`` seed's step-1 trigger_full_sync) must use
        this helper instead.

        Creates parent folders as needed. Idempotent: modifies if the file
        already exists, otherwise creates.
        """
        escaped_path = json.dumps(path)
        escaped_content = json.dumps(content)
        await self.evaluate(
            f"""
            (async () => {{
                const existing = app.vault.getFileByPath({escaped_path});
                if (existing) {{
                    await app.vault.modify(existing, {escaped_content});
                    return;
                }}
                const slash = {escaped_path}.lastIndexOf('/');
                if (slash > 0) {{
                    const dir = {escaped_path}.slice(0, slash);
                    if (!app.vault.getAbstractFileByPath(dir)) {{
                        try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
                    }}
                }}
                await app.vault.create({escaped_path}, {escaped_content});
            }})()
            """,
            await_promise=True,
        )

    async def pause_incoming_sync(self) -> None:
        """Silence incoming WebSocket events by replacing handleStreamEvent.

        Used by setup_conflict_for_a to guarantee that ``pull()`` is the
        ONLY path that can detect divergence and open ConflictModal —
        without this, B's full_sync push broadcasts an upsert event to A
        which races against pull() under resolveConflict's single-flight
        gate. The race produced the test_54 PerHunk flake on PR #162.
        """
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            if (se._origHandleStreamEvent) return 'already-paused';
            se._origHandleStreamEvent = se.handleStreamEvent.bind(se);
            se.handleStreamEvent = async () => {{}};
            return 'paused';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Incoming sync paused on CDP port %d: %s", self.port, result)

    async def resume_incoming_sync(self) -> None:
        """Restore the WebSocket event handler saved by pause_incoming_sync()."""
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            if (!se._origHandleStreamEvent) return 'not-paused';
            se.handleStreamEvent = se._origHandleStreamEvent;
            delete se._origHandleStreamEvent;
            return 'resumed';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Incoming sync resumed on CDP port %d: %s", self.port, result)

    async def rename_file(self, old_path: str, new_path: str) -> None:
        """Rename a file through Obsidian's vault API (triggers handleRename)."""
        escaped_old = json.dumps(old_path)
        escaped_new = json.dumps(new_path)
        js = f"""
        (async function() {{
            const file = app.vault.getAbstractFileByPath({escaped_old});
            if (!file) throw new Error('File not found: ' + {escaped_old});
            await app.vault.rename(file, {escaped_new});
            return 'renamed';
        }})()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Renamed %s → %s: %s", old_path, new_path, result)

    async def restore_conflict_handler(self) -> None:
        """Restore the original modal-based conflict handler.

        Re-wires the handler that opens ConflictModal.
        """
        js = f"""
        (function() {{
            const plugin = {PLUGIN_PATH};
            const ConflictModal = require('{PLUGIN_ID}').ConflictModal
                || plugin.app.plugins.plugins['{PLUGIN_ID}'].constructor.__ConflictModal;
            // Fallback: set to null so SyncEngine uses its default skip behavior
            plugin.syncEngine.onConflict = null;
        }})()
        """
        try:
            await self.evaluate(js)
        except CdpError:
            # If we can't restore the fancy handler, null is safe (defaults to skip)
            await self.evaluate(f"{ENGINE_PATH}.onConflict = null")
        logger.info("Conflict handler restored")

    # ------------------------------------------------------------------
    # Resilience testing helpers
    # ------------------------------------------------------------------

    async def disconnect_stream(self) -> None:
        """Disconnect the real-time stream (simulates network drop)."""
        await self.evaluate(f"{PLUGIN_PATH}.noteStream.disconnect()")
        logger.info("Stream disconnected on CDP port %d", self.port)


    async def reconnect_stream(self) -> None:
        """Reconnect the real-time stream after a disconnect.

        For WebSocket channels, connect() opens a new WebSocket and re-joins.
        """
        await self.evaluate(f"{PLUGIN_PATH}.noteStream.connect()")
        logger.info("Stream reconnect initiated on CDP port %d", self.port)
        # Wait for the connection to establish and trigger onStatusChange
        for _ in range(10):
            await asyncio.sleep(1)
            if await self.check_stream_connected():
                logger.info("Stream reconnected on CDP port %d", self.port)
                return
        logger.warning("Stream did not reconnect within 10s on CDP port %d", self.port)


    async def simulate_offline(self) -> None:
        """Override API methods to throw, simulating network failure.

        Saves originals so restore_online() can bring the plugin back.
        Also overrides health() to prevent auto-recovery via health checks.
        """
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            se._origPushNote = se.api.pushNote.bind(se.api);
            se._origPushNotesBatch = se.api.pushNotesBatch.bind(se.api);
            se._origDeleteNote = se.api.deleteNote.bind(se.api);
            se._origPushAttachment = se.api.pushAttachment.bind(se.api);
            se._origDeleteAttachment = se.api.deleteAttachment.bind(se.api);
            se._origHealth = se.api.health.bind(se.api);
            const fail = async () => {{ throw new Error('simulated offline'); }};
            se.api.pushNote = fail;
            // pushNotesBatch (POST /notes/batch, protocol rev #557) is a SEPARATE
            // method — without overriding it too, multi-file pushes that coalesce
            // into a batch bypass the simulation, the real call succeeds, and the
            // engine flips back online (goOnline) so it never goes offline (#635).
            se.api.pushNotesBatch = fail;
            se.api.deleteNote = fail;
            se.api.pushAttachment = fail;
            se.api.deleteAttachment = fail;
            se.api.health = async () => false;
            // Drive the REAL offline transition deterministically instead of
            // waiting for the engine to react to a failed push. The engine
            // only flips `offline` on its health/error path (a push must fire,
            // fail, and categorize as network) — under e2e-clerk load that
            // reaction lags past the test's poll window, so `assert offline`
            // and the restore-time queue flush raced and failed (#635).
            // goOffline() sets offline + starts the health-check loop; with
            // health() stubbed to false above, nothing flips it back until
            // restore_online() calls goOnline(). Using the engine's own
            // transition (vs. poking the flag) keeps the health-check timer
            // state consistent so restore is symmetric.
            se.goOffline();
            return 'offline simulated';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Offline simulated on CDP port %d: %s", self.port, result)

    async def restore_online(self) -> None:
        """Restore original API methods after simulate_offline().

        Calls goOnline() if the engine is in offline state, which triggers
        queue flush automatically.
        """
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            if (se._origPushNote) se.api.pushNote = se._origPushNote;
            if (se._origPushNotesBatch) se.api.pushNotesBatch = se._origPushNotesBatch;
            if (se._origDeleteNote) se.api.deleteNote = se._origDeleteNote;
            if (se._origPushAttachment) se.api.pushAttachment = se._origPushAttachment;
            if (se._origDeleteAttachment) se.api.deleteAttachment = se._origDeleteAttachment;
            if (se._origHealth) se.api.health = se._origHealth;
            delete se._origPushNote;
            delete se._origPushNotesBatch;
            delete se._origDeleteNote;
            delete se._origPushAttachment;
            delete se._origDeleteAttachment;
            delete se._origHealth;
            // Drive the REAL online transition: clears `offline` (so file
            // events stop being re-enqueued mid-flush), stops the health-check
            // timer, and kicks off a flush. Symmetric with goOffline() in
            // simulate_offline(); the awaited flushQueue() below then makes the
            // drain deterministic. Without going online the engine stays in
            // offline-enqueue mode and the queue oscillates instead of draining.
            if (se.offline) se.goOnline();
            return 'online restored';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Online restored on CDP port %d: %s", self.port, result)
        # Always drain the queue explicitly, awaited. Previously this was gated
        # on `get_offline_status()` being true — but the engine's health check
        # can auto-recover (flip online) before this check, which skipped the
        # explicit flush and left the queue to drain via the slow auto-retry
        # loop, intermittently blowing the drain timeout (#635). flushQueue is a
        # no-op on an empty queue and idempotent on the server, so calling it
        # unconditionally is safe and makes the drain deterministic.
        await self.evaluate(f"{ENGINE_PATH}.flushQueue()", await_promise=True)

    async def get_queue_size(self) -> int:
        """Read the offline queue size."""
        result = await self.evaluate(f"{ENGINE_PATH}.queue.size")
        return result if isinstance(result, int) else 0

    async def wait_for_queue_drain(self, timeout: float = 10, poll: float = 0.5) -> None:
        """Poll until the offline queue is empty."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            size = await self.get_queue_size()
            if size == 0:
                return
            await asyncio.sleep(poll)
        raise TimeoutError(
            f"Queue not drained after {timeout}s, size={await self.get_queue_size()}"
        )

    async def get_queue_entries(self) -> list[dict]:
        """Dump queue entries for diagnostics (path, action, timestamp)."""
        result = await self.evaluate(
            f"JSON.stringify({ENGINE_PATH}.queue.all().map("
            f"e => ({{path: e.path, action: e.action, kind: e.kind, ts: e.timestamp}})))"
        )
        if isinstance(result, str):
            import json as _json
            return _json.loads(result)
        return []

    async def clear_queue(self) -> None:
        """Clear the offline queue (for test isolation)."""
        await self.evaluate(f"{ENGINE_PATH}.queue.entries.clear()")
        logger.info("Queue cleared on CDP port %d", self.port)

    async def reset_sync_state(self) -> None:
        """Clear the offline queue AND sync issues for per-test isolation.

        Quiet, best-effort sibling of clear_queue() used by the per-test
        autouse fixture. The Obsidian instances are session-scoped but
        settings.vaultId churns per test (each test re-registers its vault).
        The offline queue keys entries by `{vaultId}:{path}` and flushQueue
        dequeues by the CURRENT settings.vaultId, so an entry enqueued under
        an earlier test's vaultId can never be dequeued and lingers forever
        (`queue.size` counts entries across ALL vaultIds). Clearing both
        stores between tests stops that cross-test leakage. See engram#635.
        """
        await self.evaluate(
            f"""
            (function() {{
                const se = {ENGINE_PATH};
                if (se && se.queue && se.queue.entries) se.queue.entries.clear();
                if (se && se.issues && typeof se.issues.clearAll === 'function') {{
                    se.issues.clearAll();
                }}
                return 'reset';
            }})()
            """
        )

    async def persist_plugin_data(self) -> None:
        """Synchronously flush settings + queue + sync state to data.json.

        The plugin debounces writes by default; tests that hard-kill the
        Obsidian process (test_31 restart) need to force a flush so all
        on-disk state survives the crash. Drives the plugin's own
        savePluginData so the payload never drifts from what the plugin
        actually persists (private in TS, accessible at runtime).
        """
        await self.evaluate(
            """
            (async () => {
                const p = app.plugins.plugins['engram-vault-sync'];
                await p.savePluginData(p.syncEngine.getLastSync());
                return 'saved';
            })()
            """,
            await_promise=True,
        )

    async def get_offline_status(self) -> bool:
        """Read whether the engine is in offline mode."""
        result = await self.evaluate(f"{ENGINE_PATH}.offline")
        return result is True

    async def get_last_error(self) -> str:
        """Read the engine's last error message."""
        result = await self.evaluate(f"{ENGINE_PATH}.lastError")
        return result if isinstance(result, str) else ""

    async def enable_remote_logging(self) -> None:
        """Enable remote logging via plugin settings and trigger save.

        Remote logging is one facet of the single ``diagnosticsEnabled`` toggle
        (plugin collapsed remoteLoggingEnabled/diagnosticMode/tracingEnabled into
        it); saveSettings() gates rlog().setEnabled on it.
        """
        js = f"""
        (async function() {{
            const plugin = {PLUGIN_PATH};
            plugin.settings.diagnosticsEnabled = true;
            await plugin.saveSettings();
            return 'enabled';
        }})()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Remote logging enabled on CDP port %d: %s", self.port, result)

    async def flush_remote_logs(self, wait_ms: int = 600) -> None:
        """Force-flush remote logs by simulating document hidden state.

        The plugin flushes rlog on visibilitychange→hidden. We temporarily
        override visibilityState on the document instance, dispatch the
        event, then delete the override to restore the prototype getter.

        ``wait_ms`` controls how long to wait inside the renderer for the
        POST /logs request to complete. Default 600 ms covers a typical
        local round-trip; bump it on slow CI shapes. The previous default
        of 3000 ms was overkill — most flushes complete in well under
        500 ms.
        """
        js = f"""
        (async function() {{
            Object.defineProperty(document, 'visibilityState', {{
                value: 'hidden', configurable: true
            }});
            document.dispatchEvent(new Event('visibilitychange'));
            // Remove instance override to restore prototype getter
            delete document.visibilityState;
            // Wait for the async flush HTTP request to complete
            await new Promise(r => setTimeout(r, {int(wait_ms)}));
            return 'flushed';
        }})()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Remote logs flushed on CDP port %d: %s", self.port, result)

    # ------------------------------------------------------------------
    # Step 1: SearchModal helpers
    # ------------------------------------------------------------------

    async def open_search_modal(self) -> None:
        """Run the `search` command — opens SearchModal."""
        await self.evaluate(
            "app.commands.executeCommandById('engram-vault-sync:search')"
        )

    async def wait_for_search_modal(self, timeout: float = 5) -> None:
        """Block until the search modal mounts."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            present = await self.evaluate(
                "Boolean(document.querySelector('.engram-search-modal "
                "input.engram-search-input'))"
            )
            if present:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError("SearchModal did not mount")

    async def type_search_query(self, query: str) -> None:
        """Fill the SearchModal input and dispatch input event."""
        await self.evaluate(
            f"(() => {{const i = document.querySelector("
            f"'.engram-search-modal input.engram-search-input'); "
            f"i.value = {json.dumps(query)}; "
            f"i.dispatchEvent(new Event('input', {{bubbles: true}})); }})()"
        )

    async def get_search_results(self) -> list[dict]:
        """Snapshot rendered results as [{title, folder, snippet}].

        NOTE: source classes are .engram-search-result-title,
        .engram-search-result-path, .engram-search-result-snippet
        on .engram-search-result-item elements.
        Plan used .engram-search-result / .title / .folder / .snippet
        which do not exist in the source — corrected here.
        """
        return await self.evaluate(
            "Array.from(document.querySelectorAll("
            "'.engram-search-modal .engram-search-result-item')).map("
            "el => ({title: el.querySelector('.engram-search-result-title')?.textContent, "
            "folder: el.querySelector('.engram-search-result-path')?.textContent, "
            "snippet: el.querySelector('.engram-search-result-snippet')?.textContent}))"
        )

    # ------------------------------------------------------------------
    # Step 2: SearchView (sidebar) helpers
    # ------------------------------------------------------------------

    async def open_search_sidebar(self) -> None:
        """Run the open-search-sidebar command."""
        await self.evaluate(
            "app.commands.executeCommandById("
            "'engram-vault-sync:open-search-sidebar')"
        )

    async def wait_for_search_view(self, timeout: float = 5) -> None:
        """Block until the SearchView leaf is mounted."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            present = await self.evaluate(
                "Boolean(document.querySelector('.workspace-leaf-content"
                "[data-type=\"engram-search-view\"]'))"
            )
            if present:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError("SearchView did not mount")

    # ------------------------------------------------------------------
    # Step 3: ConflictModal interaction helpers
    # ------------------------------------------------------------------
    #
    # SELECTOR CONCERNS (see report):
    #   - get_conflict_view_mode: plan queried '[data-view-mode]' which does
    #     not exist in source. We query the active button inside
    #     .engram-conflict-view-toggle instead.
    #   - toggle_conflict_view: plan used .engram-view-toggle (missing);
    #     corrected to .engram-conflict-view-toggle.
    #   - click_all_local / click_all_remote: plan used .engram-all-local /
    #     .engram-all-remote (missing); corrected to text-based button search
    #     inside .engram-conflict-bulk.
    #   - pick_conflict_hunk: plan used .engram-hunk (missing) and
    #     [data-side=...] (missing); corrected to .engram-conflict-hunk and
    #     button text "Use local" / "Use remote".
    #   - set_merge_editor: plan used textarea.engram-merge-editor (missing);
    #     corrected to .engram-conflict-merge-editor.
    #   - click_conflict_accept: plan used .engram-accept (missing);
    #     corrected to button text "Apply merge" inside .engram-conflict-actions.
    #   - click_conflict_skip: plan used .engram-skip (missing);
    #     corrected to button text "Skip" inside .engram-conflict-actions.

    async def get_conflict_view_mode(self) -> str:
        """Return 'unified' or 'side-by-side' based on the active toggle button.

        Reads the active button text inside .engram-conflict-view-toggle.
        Source has no data-view-mode attribute — plan selector was speculative.
        """
        return await self.evaluate(
            "(() => {"
            "const toggle = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-view-toggle');"
            "if (!toggle) return null;"
            "const active = toggle.querySelector('button.is-active');"
            "if (!active) return null;"
            "const t = active.textContent.trim().toLowerCase();"
            "return t === 'side-by-side' ? 'side-by-side' : 'unified';"
            "})()"
        )

    async def toggle_conflict_view(self) -> None:
        """Click the non-active view button in .engram-conflict-view-toggle."""
        await self.evaluate(
            "(() => {"
            "const toggle = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-view-toggle');"
            "if (!toggle) return;"
            "const inactive = Array.from(toggle.querySelectorAll('button'))"
            ".find(b => !b.classList.contains('is-active'));"
            "if (inactive) inactive.click();"
            "})()"
        )

    async def click_all_local(self) -> None:
        """Click the 'All local' bulk button inside .engram-conflict-bulk."""
        await self.evaluate(
            "(() => {"
            "const bulk = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-bulk');"
            "if (!bulk) return;"
            "Array.from(bulk.querySelectorAll('button'))"
            ".find(b => b.textContent.trim() === 'All local')?.click();"
            "})()"
        )

    async def click_all_remote(self) -> None:
        """Click the 'All remote' bulk button inside .engram-conflict-bulk."""
        await self.evaluate(
            "(() => {"
            "const bulk = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-bulk');"
            "if (!bulk) return;"
            "Array.from(bulk.querySelectorAll('button'))"
            ".find(b => b.textContent.trim() === 'All remote')?.click();"
            "})()"
        )

    async def pick_conflict_hunk(self, index: int, side: str) -> None:
        """Click 'Use local' or 'Use remote' in a hunk by index.

        side ∈ {'local', 'remote'}. Source uses button text 'Use local' /
        'Use remote' inside .engram-conflict-hunk-controls — no data-side.
        """
        label = "Use local" if side == "local" else "Use remote"
        await self.evaluate(
            f"(() => {{"
            f"const hunk = document.querySelectorAll("
            f"'.engram-conflict-modal .engram-conflict-hunk')[{index}];"
            f"if (!hunk) return;"
            f"const label = {json.dumps(label)};"
            f"Array.from(hunk.querySelectorAll('.engram-conflict-hunk-controls button'))"
            f".find(b => b.textContent.trim() === label)?.click();"
            f"}})()"
        )

    async def set_merge_editor(self, content: str) -> None:
        """Set the merge editor textarea value and fire input + change events."""
        await self.evaluate(
            f"(() => {{const t = document.querySelector("
            f"'.engram-conflict-modal .engram-conflict-merge-editor'); "
            f"t.value = {json.dumps(content)}; "
            f"t.dispatchEvent(new Event('input', {{bubbles: true}})); "
            f"t.dispatchEvent(new Event('change', {{bubbles: true}})); }})()"
        )

    async def click_conflict_accept(self) -> None:
        """Click 'Apply merge' in the conflict modal actions footer."""
        await self.evaluate(
            "(() => {"
            "const footer = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-actions');"
            "if (!footer) return;"
            "Array.from(footer.querySelectorAll('button'))"
            ".find(b => b.textContent.trim() === 'Apply merge')?.click();"
            "})()"
        )

    async def click_conflict_skip(self) -> None:
        """Click 'Skip' in the conflict modal actions footer."""
        await self.evaluate(
            "(() => {"
            "const footer = document.querySelector("
            "'.engram-conflict-modal .engram-conflict-actions');"
            "if (!footer) return;"
            "Array.from(footer.querySelectorAll('button'))"
            ".find(b => b.textContent.trim() === 'Skip')?.click();"
            "})()"
        )

    async def wait_for_conflict_modal_closed(self, timeout: float = 10) -> None:
        """Poll until .engram-conflict-modal is gone from the DOM.

        Distinct from wait_for_modal_closed() which targets the sync-preview
        modal.  Conflict resolution can involve a full-sync round-trip so the
        default timeout is more generous (10 s vs 5 s).
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            present = await self.evaluate(
                "Boolean(document.querySelector('.engram-conflict-modal'))"
            )
            if not present:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError(
            f"ConflictModal still mounted after {timeout}s on CDP port {self.port}"
        )

    # ------------------------------------------------------------------
    # Step 4: SyncPreviewModal destructive confirm helpers
    # ------------------------------------------------------------------
    #
    # SELECTOR CONCERNS (see report):
    #   - Plan used input.engram-destructive-confirm and
    #     .engram-destructive-submit — neither exists in source.
    #     Source uses .engram-sync-preview-confirm-input and
    #     .engram-sync-preview-confirm-btn — corrected here.

    async def type_destructive_confirm(self, text: str = "delete") -> None:
        """Type into the destructive-confirm input and fire input event."""
        await self.evaluate(
            f"(() => {{const i = document.querySelector("
            f"'.engram-sync-preview-modal .engram-sync-preview-confirm-input'); "
            f"i.value = {json.dumps(text)}; "
            f"i.dispatchEvent(new Event('input', {{bubbles: true}})); }})()"
        )

    async def destructive_submit_enabled(self) -> bool:
        """Return True when the destructive confirm button is enabled."""
        return await self.evaluate(
            "(() => {const b = document.querySelector("
            "'.engram-sync-preview-modal .engram-sync-preview-confirm-btn'); "
            "return Boolean(b) && !b.disabled; })()"
        )

    # ------------------------------------------------------------------
    # Step 5: Sync Center DOM helpers
    # ------------------------------------------------------------------
    #
    # SELECTOR CONCERNS (see report):
    #   - Plan used many selectors (.engram-issue-group, .engram-issue,
    #     data-category, data-count, data-path, data-action, data-status,
    #     .engram-ignored-item, .engram-restore, .engram-activity-entry,
    #     .engram-clear-activity) that do not exist in source.
    #   - Source uses: .engram-sync-center-card (needs-attention, title in
    #     .engram-sync-center-card-title), .engram-sync-center-issue-row,
    #     .engram-sync-center-activity-row (text contains category label +
    #     count), button text "Open"/"Ignore"/"Restore",
    #     .engram-sync-center-activity-action, etc.
    #   - Data attributes (data-category, data-count, data-path, data-action,
    #     data-status) are ABSENT from the plugin source — helpers below use
    #     structural/text queries instead. Tests that depend on .dataset will
    #     need the plugin to add these attributes.

    async def open_sync_center(self) -> None:
        """Run the open-sync-center command."""
        await self.evaluate(
            "app.commands.executeCommandById("
            "'engram-vault-sync:open-sync-center')"
        )

    async def get_issue_groups(self) -> list[dict]:
        """Return [{category, count, items: [{path, actions:[...]}]}].

        The Sync Center "Needs attention" area renders one card per failure
        reason (.engram-sync-center-card): category from the card title, file
        rows from .engram-sync-center-issue-row inside (in a collapsed "Show
        files" expander — still in the DOM). Source has no data-* attributes,
        so we parse structurally.
        """
        return await self.evaluate(
            "Array.from(document.querySelectorAll("
            "'.engram-sync-center .engram-sync-center-card')).map(c => ({"
            "category: c.querySelector('.engram-sync-center-card-title')"
            "?.textContent?.trim() || '',"
            "count: c.querySelectorAll('.engram-sync-center-issue-row').length,"
            "items: Array.from(c.querySelectorAll('.engram-sync-center-issue-row')).map(i => ({"
            "path: i.querySelector('.engram-sync-center-issue-path')?.textContent?.trim() || '',"
            "actions: Array.from(i.querySelectorAll('.engram-sync-center-issue-actions button'))"
            ".map(b => b.textContent.trim())}))"
            "}))"
        )

    async def click_issue_action(self, path: str, action: str) -> None:
        """Click an action button ('Open' or 'Ignore') for an issue row by path.

        Matches rows by .engram-sync-center-issue-path text content since
        data-path attribute is absent from source.
        """
        await self.evaluate(
            f"(() => {{"
            f"const rows = document.querySelectorAll("
            f"'.engram-sync-center .engram-sync-center-issue-row');"
            f"for (const row of rows) {{"
            f"const pathEl = row.querySelector('.engram-sync-center-issue-path');"
            f"if (pathEl?.textContent?.trim() !== {json.dumps(path)}) continue;"
            f"const btn = Array.from(row.querySelectorAll("
            f"'.engram-sync-center-issue-actions button'))"
            f".find(b => b.textContent.trim() === {json.dumps(action)});"
            f"if (btn) {{ btn.click(); return; }}"
            f"}}"
            f"}})()"
        )

    async def get_ignored_files(self) -> list[str]:
        """Return paths of all ignored files from the Ignored section.

        Reads .engram-sync-center-issue-path text from the Ignored section's
        issue rows. Source has no .engram-ignored-item class.
        """
        return await self.evaluate(
            "(() => {"
            "const sections = document.querySelectorAll("
            "'.engram-sync-center .engram-sync-center-section');"
            "for (const s of sections) {"
            "const h = s.querySelector('.setting-item-name');"
            "if (!h || !h.textContent.includes('Ignored')) continue;"
            "return Array.from(s.querySelectorAll('.engram-sync-center-issue-path'))"
            ".map(el => el.textContent.trim());"
            "}"
            "return [];"
            "})()"
        )

    async def click_restore_ignored(self, path: str) -> None:
        """Click 'Restore' for an ignored file row matching path."""
        await self.evaluate(
            f"(() => {{"
            f"const rows = document.querySelectorAll("
            f"'.engram-sync-center .engram-sync-center-issue-row');"
            f"for (const row of rows) {{"
            f"const pathEl = row.querySelector('.engram-sync-center-issue-path');"
            f"if (pathEl?.textContent?.trim() !== {json.dumps(path)}) continue;"
            f"const btn = Array.from(row.querySelectorAll("
            f"'.engram-sync-center-issue-actions button'))"
            f".find(b => b.textContent.trim() === 'Restore');"
            f"if (btn) {{ btn.click(); return; }}"
            f"}}"
            f"}})()"
        )

    async def get_activity_entries(self) -> list[dict]:
        """Return [{action, path, status}] from the activity list.

        Source has no data-action / data-path / data-status attributes —
        reads .engram-sync-center-activity-action, -path text content and
        infers status from the row's CSS class (is-ok, is-error, is-skipped).
        """
        return await self.evaluate(
            "Array.from(document.querySelectorAll("
            "'.engram-sync-center .engram-sync-center-activity-row')).map(el => ({"
            "action: el.querySelector('.engram-sync-center-activity-action')"
            "?.textContent?.trim() || '',"
            "path: el.querySelector('.engram-sync-center-activity-path')"
            "?.textContent?.trim() || '',"
            "status: el.classList.contains('is-ok') ? 'ok' "
            ": el.classList.contains('is-error') ? 'error' "
            ": el.classList.contains('is-skipped') ? 'skipped' : ''}))"
        )

    async def click_clear_activity(self) -> None:
        """Click the 'Clear' button in the Activity section heading.

        The button is injected by Obsidian's Setting.addButton API — no
        stable custom class. We find it by looking for a button with text
        'Clear' inside the Activity section's setting-item container.
        """
        await self.evaluate(
            "(() => {"
            "const sections = document.querySelectorAll("
            "'.engram-sync-center .engram-sync-center-section');"
            "for (const s of sections) {"
            "const h = s.querySelector('.setting-item-name');"
            "if (!h || !h.textContent.includes('Activity')) continue;"
            "const btn = Array.from(s.querySelectorAll('.setting-item-control button'))"
            ".find(b => b.textContent.trim() === 'Clear');"
            "if (btn) { btn.click(); return; }"
            "}"
            "})()"
        )

    # ------------------------------------------------------------------
    # Step 6: Settings / command / status-bar / ribbon helpers
    # ------------------------------------------------------------------
    #
    # SELECTOR CONCERNS (see report):
    #   - Plan used .engram-status-bar-item — source uses
    #     .engram-status-bar-clickable — corrected here.

    async def open_settings_tab(self, tab: str) -> None:
        """Open plugin settings and navigate to a sub-tab.

        tab ∈ {'cloud','self-hosted','sync-center','advanced'}
        """
        await self.evaluate(
            "app.commands.executeCommandById("
            "'app:open-settings'); app.setting.openTabById("
            f"'engram-vault-sync'); app.setting.activeTab.selectSubtab("
            f"{json.dumps(tab)})"
        )

    async def run_command(self, command_id: str) -> None:
        """Execute a plugin command. Prepends plugin prefix if bare id given."""
        full = (
            command_id
            if ":" in command_id
            else f"engram-vault-sync:{command_id}"
        )
        await self.evaluate(
            f"app.commands.executeCommandById({json.dumps(full)})"
        )

    async def click_status_bar(self) -> None:
        """Click the Engram status bar item."""
        await self.evaluate(
            "document.querySelector('.status-bar "
            ".engram-status-bar-clickable').click()"
        )

    async def get_status_bar_text(self) -> str:
        """Read the Engram status bar item text."""
        return await self.evaluate(
            "document.querySelector('.status-bar "
            ".engram-status-bar-clickable')?.textContent || ''"
        )

    async def click_ribbon(self) -> None:
        """Click the Engram ribbon icon (aria-label contains 'Engram')."""
        await self.evaluate(
            "Array.from(document.querySelectorAll('.side-dock-ribbon-action'))"
            ".find(el => el.getAttribute('aria-label')?.includes('Engram'))"
            ".click()"
        )

    # ------------------------------------------------------------------
    # Step 7: has_* skip-gate helpers
    # ------------------------------------------------------------------

    async def has_search_modal(self) -> bool:
        """True when the plugin exposes the 'search' command."""
        return await self.evaluate(
            "Boolean(app.commands.findCommand("
            "'engram-vault-sync:search'))"
        )

    async def has_sync_center(self) -> bool:
        """True when the plugin exposes the 'open-sync-center' command."""
        return await self.evaluate(
            "Boolean(app.commands.findCommand("
            "'engram-vault-sync:open-sync-center'))"
        )

    async def has_command(self, command_id: str) -> bool:
        """True when the plugin exposes the given command id."""
        return await self.evaluate(
            f"Boolean(app.commands.findCommand("
            f"'engram-vault-sync:{command_id}'))"
        )

    async def has_ribbon(self) -> bool:
        """True when an Engram ribbon icon is present in the sidebar."""
        return await self.evaluate(
            "Array.from(document.querySelectorAll('.side-dock-ribbon-action'))"
            ".some(el => el.getAttribute('aria-label')?.includes('Engram'))"
        )

    # ------------------------------------------------------------------
    # Step 11: SyncProgressModal helpers
    # ------------------------------------------------------------------
    #
    # SELECTOR CORRECTIONS vs plan draft:
    #   - Plan used `.engram-phase`; source uses `.engram-progress-phase`
    #     (sync-progress-modal.ts line 50: cls: "engram-progress-phase").
    #   - Plan used `progress` element; source has no <progress> tag.
    #     The bar is a div.engram-progress-bar-inner with inline style.width.
    #     get_progress_percent() parses the width percentage from that style.
    #   - Plan used `.engram-bg-btn`; the button has no CSS class in source.
    #     click_progress_background() matches by text "Run in background"
    #     inside .engram-progress-buttons.

    async def get_progress_phase(self) -> str | None:
        """Read the phase label text from the SyncProgressModal.

        Returns None when the modal is not mounted.  Source class is
        .engram-progress-phase (plan draft used .engram-phase — corrected).
        """
        return await self.evaluate(
            "document.querySelector("
            "'.engram-sync-progress-modal .engram-progress-phase')?.textContent"
        )

    async def get_progress_percent(self) -> int | None:
        """Return the progress bar fill as an integer percentage (0–100).

        Reads the inline style.width from div.engram-progress-bar-inner.
        The modal uses a CSS-width div, not a <progress> element — plan draft
        used ``progress[value]`` which does not exist in source.
        Returns None when the modal is not mounted or width is not set.
        """
        return await self.evaluate(
            "(() => {"
            "const bar = document.querySelector("
            "'.engram-sync-progress-modal .engram-progress-bar-inner');"
            "if (!bar) return null;"
            "const w = bar.style.width;"
            "if (!w || !w.endsWith('%')) return null;"
            "return Math.round(parseFloat(w));"
            "})()"
        )

    async def click_progress_background(self) -> None:
        """Click the 'Run in background' button to dismiss the progress modal.

        The button has no CSS class in source; we locate it by text content
        inside .engram-progress-buttons.  The plan draft used .engram-bg-btn
        which does not exist — corrected to text-match.
        """
        await self.evaluate(
            "(() => {"
            "const btns = document.querySelectorAll("
            "'.engram-sync-progress-modal .engram-progress-buttons button');"
            "const btn = Array.from(btns)"
            ".find(b => b.textContent.trim() === 'Run in background');"
            "if (btn) btn.click();"
            "})()"
        )

    async def wait_for_progress_modal_closed(self, timeout: float = 10) -> None:
        """Poll until .engram-sync-progress-modal is gone from the DOM."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            present = await self.evaluate(
                "Boolean(document.querySelector('.engram-sync-progress-modal'))"
            )
            if not present:
                return
            await asyncio.sleep(0.1)
        raise TimeoutError(
            f"SyncProgressModal still mounted after {timeout}s on CDP port {self.port}"
        )
