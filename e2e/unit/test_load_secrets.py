"""Load sim: live API keys never touch disk, and never reach ops.jsonl.

Delta review of #2101: the CRDT config (live keys) sat in a 0600 tempfile that
SIGTERM left behind (atexit does not run on a signal), the bun child was
orphaned, and the catch-up walk's socket URL carries `token=<key>` into any
exception text that lands in ops.jsonl.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

from load.guards import redact
from load.sim import Recorder, spawn_child

E2E = Path(__file__).resolve().parent.parent


def test_redact_strips_query_token():
    s = "ConnectionClosed: wss://x/socket/websocket?vsn=2.0.0&token=engram_AbC-123_x&device_id=d"
    out = redact(s)
    assert "engram_AbC-123_x" not in out
    assert "token=REDACTED" in out
    assert "device_id=d" in out


def test_redact_strips_bare_api_key():
    assert "engram_" + "Zz9" * 10 not in redact("key engram_" + "Zz9" * 10 + " failed")


def test_redact_leaves_plain_text():
    assert redact("status 409") == "status 409"


def test_recorder_redacts_err(tmp_path):
    rec = Recorder(tmp_path / "ops.jsonl")
    rec.rec(
        "ws_catchup_walk",
        1,
        "exc",
        False,
        "boom ?token=engram_secretsecretsecret1234&x=1",
    )
    line = (tmp_path / "ops.jsonl").read_text()
    assert "engram_secretsecretsecret1234" not in line
    assert json.loads(line)["err"].startswith("boom")


def _load_crdt_files() -> set[str]:
    return {p for p in os.listdir(tempfile.gettempdir()) if p.startswith("load-crdt-")}


def test_child_config_goes_over_stdin_not_disk(tmp_path):
    before = _load_crdt_files()
    cfg = {"sessions": [{"token": "engram_live_key_for_test"}]}
    child = spawn_child(
        [
            sys.executable,
            "-c",
            "import json,sys; print(json.load(sys.stdin)['sessions'][0]['token'])",
        ],
        cfg,
        env=dict(os.environ),
        log=tmp_path / "child.log",
    )
    assert child.wait(timeout=30) == 0
    assert (tmp_path / "child.log").read_text().strip() == "engram_live_key_for_test"
    assert _load_crdt_files() == before
    assert not any(
        p.is_file() and "engram_live_key" in p.read_text(errors="ignore")
        for p in tmp_path.iterdir()
        if p.name != "child.log"
    )


def test_sigterm_stops_the_child_and_exits(tmp_path):
    script = tmp_path / "parent.py"
    script.write_text(
        textwrap.dedent(
            f"""
            import sys, time
            sys.path.insert(0, {str(E2E)!r})
            from load.sim import spawn_child, install_signal_handlers
            child = spawn_child([sys.executable, "-c", "import sys,time; sys.stdin.read(); time.sleep(60)"],
                                {{"k": 1}}, env=None, log={str(tmp_path / "c.log")!r})
            install_signal_handlers()
            print(child.pid, flush=True)
            time.sleep(60)
            """
        )
    )
    parent = subprocess.Popen(
        [sys.executable, str(script)], stdout=subprocess.PIPE, text=True
    )
    child_pid = int(parent.stdout.readline())
    parent.send_signal(signal.SIGTERM)
    assert parent.wait(timeout=20) == 128 + signal.SIGTERM
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        # Reaped by the parent, or a zombie of a dead parent: either way not running.
        if (
            Path(f"/proc/{child_pid}/stat").exists()
            and Path(f"/proc/{child_pid}/stat").read_text().split()[2] == "Z"
        ):
            break
        time.sleep(0.1)
    else:
        os.kill(child_pid, signal.SIGKILL)
        raise AssertionError("child still running after the parent's SIGTERM")
