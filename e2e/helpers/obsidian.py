"""Obsidian process manager — starts headless Obsidian with Xvfb and CDP.

Each instance gets its own --user-data-dir for full isolation (required for
running multiple Obsidian processes simultaneously). Community plugins are
enabled via CDP after startup since fresh installs have restricted mode on.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import logging
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

import requests

from .cdp import CdpClient

logger = logging.getLogger(__name__)

DEFAULT_OBSIDIAN_BIN = Path.home() / "Applications" / "Obsidian.AppImage"
# Pre-extracted directory (created by setup-runner.sh) skips squashfs extraction
DEFAULT_OBSIDIAN_EXTRACTED = Path.home() / "Applications" / "obsidian-extracted"


class ObsidianInstance:
    """Manages a single headless Obsidian instance on a virtual display."""

    def __init__(
        self,
        name: str,
        vault_path: Path,
        cdp_port: int,
        display: str,
        api_url: str,
        api_key: str,
        plugin_src: Path,
        obsidian_bin: Path = DEFAULT_OBSIDIAN_BIN,
        client_id: str | None = None,
        config_dir: Path | None = None,
    ):
        self.name = name
        self.vault_path = vault_path
        self.cdp_port = cdp_port
        self.display = display
        self.api_url = api_url
        self.api_key = api_key
        self.plugin_src = plugin_src
        self.obsidian_bin = obsidian_bin
        self.client_id = client_id
        # Isolated config dir per instance (overridable for parallel CI)
        self.config_dir = config_dir or Path(f"/tmp/e2e-obsidian-config-{name.lower()}")
        self.vault_id = hashlib.md5(str(vault_path).encode()).hexdigest()[:16]
        self._xvfb_proc: subprocess.Popen | None = None
        self._obsidian_proc: subprocess.Popen | None = None

    def start(self) -> None:
        """Start Xvfb, configure vault, launch Obsidian, enable plugin via CDP."""
        logger.info(
            "[%s] Starting on display %s, CDP port %d",
            self.name, self.display, self.cdp_port,
        )

        self._prepare_vault()
        self._prepare_config()
        self._start_xvfb()
        self._start_obsidian()
        self._wait_for_cdp()
        self._enable_plugin_via_cdp()

        logger.info("[%s] Fully ready", self.name)

    def stop(self) -> None:
        """Kill Obsidian (including extracted child processes) and Xvfb."""
        logger.info("[%s] Stopping", self.name)

        # Kill all processes using our user-data-dir (catches extracted binary children)
        # Must use SIGKILL — Obsidian ignores SIGTERM
        subprocess.run(
            ["pkill", "-9", "-f", f"user-data-dir={self.config_dir}"],
            capture_output=True,
        )
        time.sleep(0.5)

        for proc, label in [
            (self._obsidian_proc, "Obsidian"),
            (self._xvfb_proc, "Xvfb"),
        ]:
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
                logger.info("[%s] %s stopped", self.name, label)

        # Clean up config dir
        if self.config_dir.exists():
            shutil.rmtree(self.config_dir, ignore_errors=True)

    def _prepare_vault(self) -> None:
        """Create vault directory with plugin files and pre-configured settings."""
        if self.vault_path.exists():
            shutil.rmtree(self.vault_path)

        plugin_dir = self.vault_path / ".obsidian" / "plugins" / "engram-vault-sync"
        plugin_dir.mkdir(parents=True)

        for fname in ("main.js", "manifest.json", "styles.css"):
            src = self.plugin_src / fname
            if src.exists():
                shutil.copy2(src, plugin_dir / fname)
            elif fname == "styles.css":
                (plugin_dir / fname).write_text("")
            else:
                raise FileNotFoundError(f"Plugin file not found: {src}")

        settings = {
            "apiUrl": re.sub(r"/api/?$", "", self.api_url),
            "apiKey": self.api_key,
            "ignorePatterns": "",
            "syncIntervalMinutes": 1,
            "debounceMs": 500,
            "liveSyncEnabled": True,
            "maxFileSizeMB": 5,
        }
        if self.client_id:
            settings["clientId"] = self.client_id
        data = {
            "settings": settings,
            "lastSync": "2020-01-01T00:00:00Z",
            "offlineQueue": [],
        }
        (plugin_dir / "data.json").write_text(json.dumps(data), encoding="utf-8")

        obsidian_dir = self.vault_path / ".obsidian"
        (obsidian_dir / "community-plugins.json").write_text(
            '["engram-vault-sync"]', encoding="utf-8"
        )

        logger.info("[%s] Vault prepared at %s", self.name, self.vault_path)

    def _prepare_config(self) -> None:
        """Create isolated Obsidian config directory with our vault registered."""
        if self.config_dir.exists():
            shutil.rmtree(self.config_dir)
        self.config_dir.mkdir(parents=True)

        config = {
            "vaults": {
                self.vault_id: {
                    "path": str(self.vault_path),
                    "ts": int(time.time() * 1000),
                    "open": True,
                }
            }
        }
        (self.config_dir / "obsidian.json").write_text(json.dumps(config))
        logger.info("[%s] Config prepared at %s", self.name, self.config_dir)

    def _start_xvfb(self) -> None:
        """Start Xvfb virtual framebuffer.

        Pre-flight kills any orphan Xvfb on this display + clears its lock.
        A fixture whose setup raises after _start_xvfb (e.g., _start_obsidian
        fails) doesn't run inst.stop(), so Xvfb leaks; pytest-rerunfailures
        then recreates the fixture and the new Xvfb errors with "Server is
        already active for display N". Cleaning unconditionally is safe: only
        this test process should ever hold a display in this range.
        """
        display_num = self.display.lstrip(":")
        subprocess.run(
            ["pkill", "-9", "-f", f"Xvfb {self.display} "],
            capture_output=True,
        )
        # Wait for the killed process to release the lock, then clean.
        time.sleep(0.2)
        for path in (f"/tmp/.X{display_num}-lock", f"/tmp/.X11-unix/X{display_num}"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

        stderr_path = f"/tmp/xvfb-stderr-{display_num}-{os.getpid()}.log"
        self._xvfb_stderr = open(stderr_path, "w+b")
        self._xvfb_proc = subprocess.Popen(
            ["Xvfb", self.display, "-screen", "0", "1024x768x24", "-ac"],
            stdout=subprocess.DEVNULL,
            stderr=self._xvfb_stderr,
        )
        time.sleep(0.5)
        if self._xvfb_proc.poll() is not None:
            rc = self._xvfb_proc.returncode
            try:
                self._xvfb_stderr.flush()
                self._xvfb_stderr.seek(0)
                err = self._xvfb_stderr.read().decode("utf-8", errors="replace")
            except Exception as e:
                err = f"<could not read stderr: {e}>"
            raise RuntimeError(
                f"Xvfb failed to start on display {self.display} "
                f"(rc={rc}, stderr_path={stderr_path}):\n{err}"
            )
        logger.info("[%s] Xvfb started on %s", self.name, self.display)

    def _start_obsidian(self) -> None:
        """Launch Obsidian with isolated config.

        Prefers pre-extracted binary (skips squashfs extraction, saves ~15-30s).
        Falls back to AppImage with --appimage-extract-and-run if not available.
        """
        env = {
            "DISPLAY": self.display,
            "HOME": str(Path.home()),
            "PATH": "/usr/bin:/bin:/usr/local/bin",
        }

        # Use pre-extracted binary if available (setup-runner.sh creates this)
        extracted_bin = DEFAULT_OBSIDIAN_EXTRACTED / "obsidian"
        if extracted_bin.exists():
            cmd = [
                str(extracted_bin),
                "--no-sandbox",
                f"--remote-debugging-port={self.cdp_port}",
                "--remote-allow-origins=http://127.0.0.1",
                "--disable-gpu",
                f"--user-data-dir={self.config_dir}",
            ]
            logger.info("[%s] Using pre-extracted binary", self.name)
        else:
            cmd = [
                str(self.obsidian_bin),
                "--appimage-extract-and-run",
                "--no-sandbox",
                f"--remote-debugging-port={self.cdp_port}",
                "--remote-allow-origins=http://127.0.0.1",
                "--disable-gpu",
                f"--user-data-dir={self.config_dir}",
            ]
            logger.info("[%s] Using AppImage (no pre-extracted binary found)", self.name)

        self._obsidian_proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        logger.info("[%s] Obsidian launched (PID %d)", self.name, self._obsidian_proc.pid)

    def _wait_for_cdp(self, timeout: float = 60) -> None:
        """Poll until CDP endpoint responds."""
        deadline = time.monotonic() + timeout
        url = f"http://127.0.0.1:{self.cdp_port}/json/version"
        while time.monotonic() < deadline:
            try:
                resp = requests.get(url, timeout=2)
                if resp.status_code == 200:
                    logger.info("[%s] CDP ready", self.name)
                    return
            except requests.ConnectionError:
                pass
            time.sleep(1)
        raise TimeoutError(f"CDP not available on port {self.cdp_port} after {timeout}s")

    async def _enable_plugin_async(self) -> None:
        """Enable community plugins and load engram-vault-sync via CDP.

        Fresh Obsidian installs have restricted mode on. The gate is:
        localStorage.getItem("enable-plugin-" + app.appId) === "true"
        We set this flag, then load the plugin programmatically.
        """
        cdp = CdpClient(self.cdp_port)

        # Wait for app object to be available
        for _ in range(30):
            try:
                app_type = await cdp.evaluate("typeof app")
                if app_type == "object":
                    break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            raise TimeoutError("Obsidian app object not available")

        # Wait for vault adapter to be ready (manifests loaded)
        for _ in range(20):
            try:
                manifests = await cdp.evaluate(
                    "JSON.stringify(Object.keys(app.plugins.manifests))"
                )
                if "engram-vault-sync" in (manifests or ""):
                    break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            raise TimeoutError("Plugin manifest not found")

        # Enable community plugins by setting the localStorage flag
        await cdp.evaluate(
            'localStorage.setItem("enable-plugin-" + app.appId, "true")'
        )
        logger.info("[%s] Community plugins enabled via localStorage", self.name)

        # Load the plugin (void return — don't try to serialize the result)
        await cdp.evaluate(
            'app.plugins.loadPlugin("engram-vault-sync").then(() => "ok")',
            await_promise=True,
        )

        # Wait for syncEngine.ready
        await cdp.wait_for_plugin_ready(timeout=30)

        # First launch fires SyncPreviewModal because the sync gate has no
        # accepted fingerprint yet. The modal is part of real onboarding
        # UX; tests don't drive it manually unless they explicitly target
        # the modal flow (those tests call cdp.reset_sync_gate() afterward).
        # Accept the gate now so the engine starts in production steady-state:
        # ready, unblocked, no modal.
        await cdp.accept_sync_gate()

    def _enable_plugin_via_cdp(self) -> None:
        """Sync wrapper — calls _enable_plugin_async via asyncio.run().

        Only works when no event loop is running (e.g. during initial setup).
        For restart inside async tests, use async_start() instead.
        """
        asyncio.run(self._enable_plugin_async())

    async def async_start(self, *, restart: bool = False) -> None:
        """Start Obsidian from an async context (e.g. inside a running test).

        Same as start() but awaits the CDP plugin enablement instead of
        using asyncio.run(), which fails inside an already-running event loop.

        Args:
            restart: If True, skip vault/config prep to preserve existing state
                     (e.g. persisted offline queue in data.json).
        """
        logger.info(
            "[%s] Starting (async) on display %s, CDP port %d",
            self.name, self.display, self.cdp_port,
        )

        if not restart:
            self._prepare_vault()
        self._prepare_config()
        self._start_xvfb()
        self._start_obsidian()
        self._wait_for_cdp()
        await self._enable_plugin_async()

        logger.info("[%s] Fully ready (async)", self.name)
