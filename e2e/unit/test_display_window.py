"""Unit tests for the e2e display-window claim and release scripts.

Regression lock for run 44354068376: the e2e-clerk display window was
`GITHUB_RUN_NUMBER % 15`, so runs 9148 and 9163 both owned :180..:189 on the
same host, and one job's pre-flight `pkill -9 -f "Xvfb :$d"` killed the
other's three Obsidian displays mid-suite. A window is now an flock held for
the job's lifetime, and teardown kills only the Xvfb pids this job recorded.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

import pytest

BIN = Path(__file__).resolve().parents[2] / "ci" / "bin"
CLAIM = BIN / "claim-display-window"
RELEASE = BIN / "release-display-window"


def _claim(lock_dir: Path, family="clerk", stride=10, offset=59, slots=15) -> dict:
    out = subprocess.run(
        [str(CLAIM), family, str(stride), str(offset), str(slots)],
        env={**os.environ, "ENGRAM_CI_LOCK_DIR": str(lock_dir), "HOLD_SECONDS": "60"},
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert out.returncode == 0, out.stderr
    return dict(line.split("=", 1) for line in out.stdout.split())


def _alive(pid: int) -> bool:
    try:
        state = Path(f"/proc/{pid}/stat").read_text().split()[2]
    except FileNotFoundError:
        return False
    return state != "Z"


@pytest.fixture
def holders():
    pids: list[int] = []
    yield pids
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def test_concurrent_claims_get_distinct_windows(tmp_path, holders):
    # Two jobs on one host, whatever their run numbers: never one window.
    a = _claim(tmp_path)
    b = _claim(tmp_path)
    holders += [int(a["holder_pid"]), int(b["holder_pid"])]
    assert (a["slot"], a["min"], a["max"], a["base"]) == ("0", "50", "59", "59")
    assert (b["slot"], b["min"], b["max"]) == ("1", "60", "69")
    assert a["resumed_base"] == "53"


def test_window_is_free_again_once_its_holder_dies(tmp_path, holders):
    a = _claim(tmp_path)
    os.kill(int(a["holder_pid"]), signal.SIGKILL)
    deadline = time.monotonic() + 5
    while _alive(int(a["holder_pid"])) and time.monotonic() < deadline:
        time.sleep(0.05)
    again = _claim(tmp_path)
    holders.append(int(again["holder_pid"]))
    assert again["slot"] == "0"


def test_no_free_window_fails_loudly(tmp_path, holders):
    first = _claim(tmp_path, slots=1)
    holders.append(int(first["holder_pid"]))
    out = subprocess.run(
        [str(CLAIM), "clerk", "10", "59", "1"],
        env={**os.environ, "ENGRAM_CI_LOCK_DIR": str(tmp_path)},
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert out.returncode != 0 and "no free display window" in out.stderr


def _fake_xvfb(display: int) -> subprocess.Popen:
    # A process whose command line reads `Xvfb :<display> ...`, like the real one.
    return subprocess.Popen(
        ["bash", "-c", f"exec -a Xvfb python3 -c 'import time; time.sleep(60)' :{display}"],
    )


def test_release_kills_only_this_jobs_recorded_xvfb(tmp_path, holders):
    window = _claim(tmp_path)
    holders.append(int(window["holder_pid"]))
    mine = _fake_xvfb(55)
    neighbour = _fake_xvfb(56)  # inside the range, but not ours: must survive
    prefix = tmp_path / "e2e-obsidian-config-run"
    Path(f"{prefix}-a.xvfb.pid").write_text(f"{mine.pid} 55\n")
    # A recorded pid that was reused by an unrelated process is not killed.
    stranger = subprocess.Popen(["sleep", "60"])
    Path(f"{prefix}-b.xvfb.pid").write_text(f"{stranger.pid} 57\n")
    try:
        out = subprocess.run(
            [str(RELEASE), str(prefix), window["holder_pid"]],
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert out.returncode == 0, out.stderr
        assert mine.wait(timeout=5) == -signal.SIGKILL
        assert neighbour.poll() is None, "a neighbour's Xvfb in the range was killed"
        assert stranger.poll() is None, "a reused pid was killed"
        holder = int(window["holder_pid"])
        deadline = time.monotonic() + 5
        while _alive(holder) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not _alive(holder), "the window lock was not released"
    finally:
        for p in (mine, neighbour, stranger):
            p.kill()
