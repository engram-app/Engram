"""Unit tests for the e2e display-window claim and release scripts.

Regression lock (not a reproduction: without the fix these fail because the
scripts do not exist) for run 44354068376: the e2e-clerk display window was
`GITHUB_RUN_NUMBER % 15`, so runs 9148 and 9163 both owned :180..:189 on the
same host, and one job's pre-flight `pkill -9 -f "Xvfb :$d"` killed the
other's three Obsidian displays mid-suite. A window is now an flock held for
the job's lifetime, and teardown kills only the Xvfb pids this job recorded.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
import time
from pathlib import Path

import pytest

from helpers.proc import pid_alive

BIN = Path(__file__).resolve().parents[2] / "ci" / "bin"
CLAIM = BIN / "claim-display-window"
RELEASE = BIN / "release-display-window"


def _claim(lock_dir: Path, family="clerk", stride=10, offset=3509, slots=15) -> dict:
    out = subprocess.run(
        [str(CLAIM), family, str(stride), str(offset), str(slots)],
        env={**os.environ, "ENGRAM_CI_LOCK_DIR": str(lock_dir), "HOLD_SECONDS": "60"},
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert out.returncode == 0, out.stderr
    return dict(line.split("=", 1) for line in out.stdout.split())


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
    assert (a["slot"], a["min"], a["max"], a["base"]) == ("0", "3500", "3509", "3509")
    assert (b["slot"], b["min"], b["max"]) == ("1", "3510", "3519")
    assert a["resumed_base"] == "3503"


def test_window_is_free_again_once_its_holder_dies(tmp_path, holders):
    a = _claim(tmp_path)
    os.kill(int(a["holder_pid"]), signal.SIGKILL)
    deadline = time.monotonic() + 5
    while pid_alive(int(a["holder_pid"])) and time.monotonic() < deadline:
        time.sleep(0.05)
    again = _claim(tmp_path)
    holders.append(int(again["holder_pid"]))
    assert again["slot"] == "0"


def test_no_free_window_fails_loudly(tmp_path, holders):
    first = _claim(tmp_path, slots=1)
    holders.append(int(first["holder_pid"]))
    out = subprocess.run(
        [str(CLAIM), "clerk", "10", "3509", "1"],
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
        while pid_alive(holder) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not pid_alive(holder), "the window lock was not released"
    finally:
        for p in (mine, neighbour, stranger):
            p.kill()


# -- the old bug, and the transition -------------------------------------------

# The old workflow (still on every branch not rebased past this fix):
#   clerk BASE = (run % 15) * 10 + 59, window :BASE-9..:BASE
#   crdt  BASE = (run % 15) * 6 + 250, window :BASE-5..:BASE
# and `pkill -9 -f "Xvfb :$d"` for every d in that window.
def _old_window(run: int, stride: int, offset: int) -> set[int]:
    base = (run % 15) * stride + offset
    return set(range(base - stride + 1, base + 1))


OLD_KILL_RANGE = set(range(50, 200)) | set(range(245, 335))
NEW_DISPLAYS = {"clerk": set(range(3500, 3650)), "crdt": set(range(4000, 4090))}


def test_old_run_number_window_shared_displays_across_runs():
    # Runs 9148 and 9163 (run 44354068376): one window, so one job's range
    # pkill killed the other's displays. The claim gives them two slots.
    assert _old_window(9148, 10, 59) == _old_window(9163, 10, 59) == set(range(180, 190))


def test_claimed_windows_match_the_workflow_and_tile_without_overlap():
    for family, (stride, offset) in {"clerk": (10, 3509), "crdt": (6, 4005)}.items():
        windows = [set(range(s * stride + offset - stride + 1, s * stride + offset + 1)) for s in range(15)]
        assert set().union(*windows) == NEW_DISPLAYS[family]
        assert sum(map(len, windows)) == len(NEW_DISPLAYS[family]), f"{family} windows overlap"


def test_no_old_workflow_pkill_can_reach_a_claimed_display():
    # `pkill -f "Xvfb :50"` is a regex search, so it also matches ":500x".
    hits = [
        (old, new)
        for old in OLD_KILL_RANGE
        for family in NEW_DISPLAYS.values()
        for new in family
        if re.search(f"Xvfb :{old}", f"Xvfb :{new} -screen 0 1024x768x24 -ac")
    ]
    assert not hits, f"old range kills reach new displays: {hits[:5]}"
    assert not (NEW_DISPLAYS["clerk"] & NEW_DISPLAYS["crdt"])


def test_unopenable_lock_dir_fails_fast(tmp_path):
    locked = tmp_path / "ro"
    locked.mkdir()
    locked.chmod(0o500)
    try:
        start = time.monotonic()
        out = subprocess.run(
            [str(CLAIM), "clerk", "10", "3509", "1"],
            env={**os.environ, "ENGRAM_CI_LOCK_DIR": str(locked)},
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert out.returncode != 0 and "no answer within" in out.stderr, out.stderr
        assert time.monotonic() - start < 15
    finally:
        locked.chmod(0o700)
