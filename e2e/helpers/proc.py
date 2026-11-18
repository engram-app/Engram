"""Process liveness for tests. One place for the /proc/<pid>/stat read."""

from __future__ import annotations

from pathlib import Path


def pid_alive(pid: int) -> bool:
    """True while `pid` is running. A zombie (state Z) is not alive.

    A pid that is gone is not alive, however it went: never existed or already
    reaped (FileNotFoundError on open), or reaped between the open and the
    read (ProcessLookupError, ESRCH, from the read of a /proc file whose task
    has just vanished). The second form made a poll loop that waits for a
    killed process to disappear crash on the very event it was waiting for.
    """
    try:
        state = Path(f"/proc/{pid}/stat").read_text().split()[2]
    except (FileNotFoundError, ProcessLookupError):
        return False
    return state != "Z"
