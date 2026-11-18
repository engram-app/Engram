"""pid_alive: a process that is gone is not alive, however it went."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from helpers import proc
from helpers.proc import pid_alive


def test_running_process_is_alive():
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        assert pid_alive(p.pid)
    finally:
        p.kill()
        p.wait()


def test_nonexistent_pid_is_not_alive():
    assert not pid_alive(2**22 + 12345)


def test_reaped_child_is_not_alive():
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    assert not pid_alive(p.pid)


def test_zombie_is_not_alive():
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    try:
        # Exited but not yet waited on: state Z until reaped.
        while Path(f"/proc/{p.pid}/stat").read_text().split()[2] != "Z":
            pass
        assert not pid_alive(p.pid)
    finally:
        p.wait()


def test_task_vanishing_mid_read_is_not_alive(monkeypatch):
    """The CI flake: open succeeds, the read raises ESRCH (ProcessLookupError)."""

    def vanish(self, *a, **kw):
        raise ProcessLookupError(3, "No such process")

    monkeypatch.setattr(proc.Path, "read_text", vanish)
    assert not pid_alive(1)
