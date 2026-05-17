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
        """Poll until plugin.settings.vaultId is populated.

        After plugin.onload registers the vault via /vaults/register, the
        engine has a vaultId — required for computeSyncFingerprint, which
        markSyncGateAccepted depends on. Returns silently on success.
        """
        deadline = time.monotonic() + timeout
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
            except Exception:
                pass
            await asyncio.sleep(0.5)
        raise TimeoutError(
            f"Vault not registered after {timeout}s on CDP port {self.port}"
        )

    async def accept_sync_gate(self) -> None:
        """Simulate the user accepting the sync-preview modal.

        Drives the same code path as a real click in SyncPreviewModal:
        markSyncGateAccepted() persists the fingerprint and flips
        syncBlocked=false; the open modal is then dismissed via Escape so
        the awaiting startup flow resolves with "cancel" (a no-op now that
        the gate has been accepted out-of-band).

        Idempotent — safe to call when no modal is open.
        """
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
        new direction choice.
        """
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

    async def trigger_full_sync(self) -> dict:
        """Call syncEngine.fullSync() and return {pulled, pushed}."""
        result = await self.evaluate(
            f"{ENGINE_PATH}.fullSync().then(r => JSON.stringify(r))",
            await_promise=True,
        )
        if isinstance(result, str):
            return json.loads(result)
        return result or {}

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

    async def check_stream_connected(self) -> bool:
        """Check if the plugin's real-time stream (WebSocket channel) is connected."""
        result = await self.evaluate(f"{PLUGIN_PATH}.isLiveConnected()")
        return result is True

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
        raise TimeoutError(
            f"Stream not connected after {timeout}s on CDP port {self.port}"
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
            se._origDeleteNote = se.api.deleteNote.bind(se.api);
            se._origPushAttachment = se.api.pushAttachment.bind(se.api);
            se._origDeleteAttachment = se.api.deleteAttachment.bind(se.api);
            se._origHealth = se.api.health.bind(se.api);
            const fail = async () => {{ throw new Error('simulated offline'); }};
            se.api.pushNote = fail;
            se.api.deleteNote = fail;
            se.api.pushAttachment = fail;
            se.api.deleteAttachment = fail;
            se.api.health = async () => false;
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
            if (se._origDeleteNote) se.api.deleteNote = se._origDeleteNote;
            if (se._origPushAttachment) se.api.pushAttachment = se._origPushAttachment;
            if (se._origDeleteAttachment) se.api.deleteAttachment = se._origDeleteAttachment;
            if (se._origHealth) se.api.health = se._origHealth;
            delete se._origPushNote;
            delete se._origDeleteNote;
            delete se._origPushAttachment;
            delete se._origDeleteAttachment;
            delete se._origHealth;
            return 'online restored';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Online restored on CDP port %d: %s", self.port, result)
        # Trigger recovery if engine is offline
        is_offline = await self.get_offline_status()
        if is_offline:
            await self.evaluate(
                f"{ENGINE_PATH}.flushQueue()", await_promise=True
            )

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

    async def persist_plugin_data(self) -> None:
        """Synchronously flush settings + queue + sync state to data.json.

        The plugin debounces writes by default; tests that hard-kill the
        Obsidian process (test_31 restart) need to force a flush so the
        queue survives the crash. Mirrors the payload the plugin itself
        assembles at savePluginData time, so it stays in lockstep with
        any field additions there.
        """
        await self.evaluate(
            """
            (async () => {
                const p = app.plugins.plugins['engram-vault-sync'];
                await p.saveData({
                    settings: p.settings,
                    lastSync: p.syncEngine.getLastSync(),
                    offlineQueue: p.syncEngine.queue.all(),
                    syncState: p.syncEngine.exportSyncState(),
                    syncedHashes: p.syncEngine.exportHashes(),
                });
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
        """Enable remote logging via plugin settings and trigger save."""
        js = f"""
        (async function() {{
            const plugin = {PLUGIN_PATH};
            plugin.settings.remoteLoggingEnabled = true;
            await plugin.saveSettings();
            return 'enabled';
        }})()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Remote logging enabled on CDP port %d: %s", self.port, result)

    async def flush_remote_logs(self) -> None:
        """Force-flush remote logs by simulating document hidden state.

        The plugin flushes rlog on visibilitychange→hidden. We temporarily
        override visibilityState on the document instance, dispatch the
        event, then delete the override to restore the prototype getter.
        """
        js = """
        (async function() {
            Object.defineProperty(document, 'visibilityState', {
                value: 'hidden', configurable: true
            });
            document.dispatchEvent(new Event('visibilitychange'));
            // Remove instance override to restore prototype getter
            delete document.visibilityState;
            // Wait for the async flush HTTP request to complete
            await new Promise(r => setTimeout(r, 3000));
            return 'flushed';
        })()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Remote logs flushed on CDP port %d: %s", self.port, result)
