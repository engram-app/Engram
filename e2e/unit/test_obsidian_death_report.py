"""Unit tests for the premature-death report — no CI stack needed.

Locks the discriminator that the "six unrelated CRDT tests failed at once"
investigations kept lacking. The tests only ever saw `ConnectionError:
[Errno 111] Connection refused` from CDP, which cannot tell a crash from an
OOM kill from another job's stray `pkill -9`. A return code can.

`-9` is the one that matters: on the shared runner VM both the OOM killer
and a display-bucket `pkill -9` collision land there. See
docs/context/e2e-simultaneous-failures-obsidian-death.md.
"""

from __future__ import annotations

import logging

from helpers.obsidian import ObsidianInstance


class _FakeProc:
    """Stands in for subprocess.Popen: only poll() and pid are read."""

    def __init__(self, returncode: int | None, pid: int = 4242) -> None:
        self._returncode = returncode
        self.pid = pid

    def poll(self) -> int | None:
        return self._returncode


def _instance() -> ObsidianInstance:
    """An instance with nothing started — we only exercise the report path."""
    return ObsidianInstance.__new__(ObsidianInstance)


def _prepare(obsidian_rc: int | None, xvfb_rc: int | None = None) -> ObsidianInstance:
    inst = _instance()
    inst.name = "A"
    inst._obsidian_proc = None if obsidian_rc is None else _FakeProc(obsidian_rc)
    inst._xvfb_proc = None if xvfb_rc is None else _FakeProc(xvfb_rc, pid=4243)
    inst._obsidian_stderr = None
    inst._xvfb_stderr = None
    return inst


def test_sigkill_is_reported_by_name(caplog) -> None:
    """rc=-9 must name SIGKILL and both of its plausible causes."""
    inst = _prepare(obsidian_rc=-9)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert len(caplog.records) == 1
    msg = caplog.records[0].getMessage()
    assert "DIED BEFORE TEARDOWN" in msg
    assert "rc=-9" in msg
    assert "SIGKILL" in msg
    # Both causes named: an engineer reading this must not conclude "OOM"
    # when another job's pkill is equally likely.
    assert "OOM" in msg
    assert "pkill" in msg


def test_live_process_reports_nothing(caplog) -> None:
    """The normal path. poll() is None, so teardown must stay quiet.

    This is the half that matters for noise: stop() samples liveness BEFORE
    its own `pkill -9`, so a healthy run must produce no error at all.
    """
    inst = _prepare(obsidian_rc=None)
    inst._obsidian_proc = _FakeProc(None)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert caplog.records == []


def test_never_started_reports_nothing(caplog) -> None:
    """start() can raise before Popen — stop() still runs, must not blow up."""
    inst = _prepare(obsidian_rc=None)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert caplog.records == []


def test_both_processes_are_reported(caplog) -> None:
    """Xvfb dying is its own signal and must not be masked by Obsidian's."""
    inst = _prepare(obsidian_rc=-9, xvfb_rc=-11)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    messages = [r.getMessage() for r in caplog.records]
    assert len(messages) == 2
    assert any("Obsidian" in m and "SIGKILL" in m for m in messages)
    assert any("Xvfb" in m and "SIGSEGV" in m for m in messages)


def test_a_clean_exit_is_not_a_death(caplog) -> None:
    """rc=0 must stay quiet.

    The AppImage launcher can exit 0 after handing off to the extracted
    binary — which is why stop() kills by user-data-dir rather than by this
    pid. Reporting that as a death would put an ERROR in every healthy
    teardown and make the signal worthless from the first run.
    """
    inst = _prepare(obsidian_rc=0)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert caplog.records == []


def test_unknown_code_falls_back_to_the_number(caplog) -> None:
    """An unmapped code must still surface, not vanish into a KeyError."""
    inst = _prepare(obsidian_rc=137)

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert "exit code 137" in caplog.records[0].getMessage()


def test_empty_stderr_is_called_out_rather_than_omitted(tmp_path, caplog) -> None:
    """An empty tail next to rc=-9 is evidence, not a missing field.

    SIGKILL gives the process no chance to write, so silence here is the
    expected shape of an OOM kill and the log should say so.
    """
    inst = _prepare(obsidian_rc=-9)
    inst._obsidian_stderr = (tmp_path / "stderr.log").open("w+b")

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert "consistent with SIGKILL" in caplog.records[0].getMessage()


def test_stderr_tail_is_included_when_present(tmp_path, caplog) -> None:
    inst = _prepare(obsidian_rc=-11)
    f = (tmp_path / "stderr.log").open("w+b")
    f.write(b"first line\nsegfault at 0xdeadbeef\n")
    inst._obsidian_stderr = f

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    assert "segfault at 0xdeadbeef" in caplog.records[0].getMessage()


def test_unreadable_stderr_does_not_mask_the_death(caplog) -> None:
    """Diagnostics must never swallow the thing they are diagnosing."""

    class _Exploding:
        def flush(self):
            raise OSError("bad fd")

    inst = _prepare(obsidian_rc=-9)
    inst._obsidian_stderr = _Exploding()

    with caplog.at_level(logging.ERROR):
        inst._report_premature_death()

    msg = caplog.records[0].getMessage()
    assert "rc=-9" in msg
    assert "could not read stderr" in msg
