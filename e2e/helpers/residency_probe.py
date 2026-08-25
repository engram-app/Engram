"""Sample CRDT room RESIDENCY — how many rooms are alive at one instant.

The companion to `room_probe`, which counts rooms ALLOCATED. Those two answer
different questions, and since the idle drain shipped they can differ by orders
of magnitude:

  * ALLOCATION is the #1409 acceptance claim ("an import must not open a room
    per note"). It is cumulative and cannot be missed by sampling.
  * RESIDENCY is what actually costs memory. `CrdtCheckpointTimer`'s idle drain
    defaults ON (300s) in every environment as of 2026-08-18, and `ci/compose.yml`
    shortens it further, so an allocated room is released long before a test ends.

`room_probe`'s docstring rightly warns that a SINGLE residency sample taken
after the fact proves nothing — a room-per-note burst comes and goes between two
samples. This module exists to be polled CONTINUOUSLY across the window instead,
so the caller can keep a running PEAK. A peak sampled every second across the
whole import cannot be dodged by a burst the way one trailing sample can.

Counts children of `Engram.Notes.CrdtDocSupervisor` (the same enumeration
`DataCase.stop_crdt_rooms/0` uses). Node-local: rooms are `:global`, so on a
multi-node cluster this undercounts. CI is single-node, which is the only place
this runs.
"""

from __future__ import annotations

from helpers.backend_rpc import backend_rpc

# ONE logical Elixir line — `bin/engram rpc` takes the expression as a single
# argv (same constraint room_probe.py documents).
_PROBE = (
    "IO.puts(length(DynamicSupervisor.which_children(Engram.Notes.CrdtDocSupervisor)))"
)


def read_resident_rooms() -> int:
    """Rooms alive on the backend node RIGHT NOW. Raises if the probe misfires."""
    out = backend_rpc(_PROBE)
    line = out.strip().splitlines()[-1]
    assert line.isdigit(), f"residency probe returned {line!r}"
    return int(line)
