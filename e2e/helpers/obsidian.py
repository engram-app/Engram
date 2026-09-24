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
        # Declared here, not just where they're opened: stop() reads them, and
        # stop() runs even when start() raised partway through.
        self._xvfb_stderr = None
        self._obsidian_stderr = None

    def start(self) -> None:
        """Start Xvfb, configure vault, launch Obsidian, enable plugin via CDP."""
        logger.info(
            "[%s] Starting on display %s, CDP port %d",
            self.name, self.display, self.cdp_port,
        )

        self._prepare_vault()
        self._prepare_config()
        self._start_xvfb()

        # The death report has to run on the FAILURE path here, not only in
        # stop(). Pytest fixtures call start() before their yield, and a
        # fixture that raises during setup never runs its teardown — so an
        # Obsidian OOM-killed during boot would raise out of _wait_for_cdp with
        # stop() never called, and produce exactly the bare `Errno 111` this
        # reporting exists to replace. That is also the likeliest moment to be
        # killed: boot is when the process is hungriest.
        try:
            self._start_obsidian()
            self._wait_for_cdp()
            self._enable_plugin_via_cdp()
        except Exception:
            self._report_premature_death()
            raise

        logger.info("[%s] Fully ready", self.name)

    def stop(self) -> None:
        """Kill Obsidian (including extracted child processes) and Xvfb."""
        logger.info("[%s] Stopping", self.name)

        # Sample liveness BEFORE the pkill below, or every teardown looks like
        # a death. A non-None code here means the process was ALREADY gone when
        # teardown ran — nobody asked it to exit, it just went.
        #
        # This is the signal the "six unrelated CRDT tests failed at once"
        # investigations kept lacking: the tests only ever saw `Errno 111
        # Connection refused` from CDP, which cannot distinguish a crash from
        # an OOM kill from a stray pkill. See
        # docs/context/e2e-simultaneous-failures-obsidian-death.md.
        self._report_premature_death()

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

    # Signals worth naming rather than leaving as a bare negative number.
    # -9 is the one that matters: the OOM killer and a stray `pkill -9` both
    # land here, and those are the two known ways an e2e Obsidian dies on the
    # shared runner VM.
    _SIGNAL_NAMES = {
        -9: "SIGKILL — OOM killer, or another job's `pkill -9`",
        -11: "SIGSEGV — crash",
        -6: "SIGABRT — crash",
        -15: "SIGTERM — something asked it to exit",
    }

    def _report_premature_death(self) -> None:
        """Log loudly if a process exited on its own before teardown."""
        for proc, label in [
            (self._obsidian_proc, "Obsidian"),
            (self._xvfb_proc, "Xvfb"),
        ]:
            if proc is None:
                continue
            rc = proc.poll()
            if rc is None:
                continue

            # rc == 0 is a CLEAN exit, not a death. It is also expected on the
            # AppImage path: the launcher can exit 0 after handing off to the
            # extracted binary, which is why stop() kills by user-data-dir
            # rather than by this pid. Treating 0 as a death would put an ERROR
            # in every healthy teardown and make the signal worthless from the
            # first run.
            if rc == 0:
                logger.debug(
                    "[%s] %s had already exited cleanly (pid %d, rc=0)",
                    self.name, label, proc.pid,
                )
                continue

            reason = self._SIGNAL_NAMES.get(rc, f"exit code {rc}")
            logger.error(
                "[%s] %s DIED BEFORE TEARDOWN (pid %d, rc=%d: %s)%s",
                self.name, label, proc.pid, rc, reason,
                self._stderr_tail(label),
            )

    def _stderr_tail(self, label: str) -> str:
        """Last few stderr lines for a dead process, or '' if we have none.

        A SIGKILL leaves nothing behind — the process never gets to write — so
        an empty tail next to rc=-9 is itself informative rather than a gap.
        """
        f = self._obsidian_stderr if label == "Obsidian" else self._xvfb_stderr
        if f is None:
            return ""
        try:
            f.flush()
            f.seek(0)
            text = f.read().decode("utf-8", errors="replace").strip()
        except Exception as e:  # noqa: BLE001 - diagnostics must never mask the death
            return f"\n  <could not read stderr: {e}>"
        if not text:
            return "\n  (stderr empty — consistent with SIGKILL)"
        tail = "\n  ".join(text.splitlines()[-10:])
        return f"\n  stderr tail:\n  {tail}"

    def read_data_json(self) -> dict:
        """Read the plugin's persisted data.json without mutating it.

        Companion to mutate_data_json — used by tests that need to poll
        persisted state (e.g. waiting for syncCursor to appear) rather than
        rewrite it.
        """
        p = self.vault_path / ".obsidian" / "plugins" / "engram-vault-sync" / "data.json"
        return json.loads(p.read_text(encoding="utf-8"))

    def mutate_data_json(self, mutator) -> None:
        """Stop-state helper: rewrite the plugin's persisted data.json.

        Call only while the instance is stopped. `mutator` receives the parsed
        dict and mutates in place (e.g. wipe noteIds, keep syncCursor) so tests
        can construct RESUMED-device states no fresh boot produces.
        """
        p = self.vault_path / ".obsidian" / "plugins" / "engram-vault-sync" / "data.json"
        data = json.loads(p.read_text(encoding="utf-8"))
        mutator(data)
        p.write_text(json.dumps(data), encoding="utf-8")

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
            # Ship client logs suite-wide (default is off). Every device's
            # receive/materialize lines (categories channel/ws/pull) then land
            # in client_logs, correlated to the #908 server breadcrumbs, so a
            # delivery flake's FIRST failing run carries client-side evidence
            # (non-deterministic flakes can't be reproduced on demand). Read by
            # helpers/log_oracle.py::wait_for_delivery. Remote logging is a facet
            # of the single diagnosticsEnabled toggle (plugin collapsed the three
            # legacy diagnostics flags into it).
            "diagnosticsEnabled": True,
        }
        # Explicitly pin the file-level CRDT sync path (spec §12a) for the
        # dedicated CRDT job. NOTE: since plugin #148 enableCrdt DEFAULTS to
        # true, so even without this key the general suite runs CRDT — the
        # backend always advertises the `crdt:` topic (CRDT is unconditional;
        # the old CRDT_ENABLED stack flag was dead config). Omitting this key
        # does NOT pin the legacy REST path.
        if os.environ.get("E2E_ENABLE_CRDT") == "true":
            settings["enableCrdt"] = True
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

        # stderr to a file, not DEVNULL — same treatment Xvfb already gets
        # above. Discarding it meant a crash left no record anywhere and every
        # death looked identical from the test side: `Errno 111`.
        stderr_path = f"/tmp/obsidian-stderr-{self.name.lower()}-{os.getpid()}.log"
        self._obsidian_stderr = open(stderr_path, "w+b")

        self._obsidian_proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=self._obsidian_stderr,
        )
        logger.info(
            "[%s] Obsidian launched (PID %d, stderr=%s)",
            self.name, self._obsidian_proc.pid, stderr_path,
        )

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
