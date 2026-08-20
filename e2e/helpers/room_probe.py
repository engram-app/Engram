"""Count CRDT rooms ALLOCATED on the backend node, broken down by the call
path that allocated each one.

Backs the #1409 acceptance criterion — "a bulk/first sync of N notes creates
O(open editors) rooms, not O(N)" — with a number instead of a hope.

Why allocation and not residency: `ci/compose.yml` sets `CRDT_IDLE_EXIT_MS`,
so rooms a regression opened at the top of a test have drained long before it
ends. Sampling `:global` afterwards measures instantaneous residency, and a
full room-per-note regression passes that assertion — the burst comes and goes
entirely between two samples. Allocation is the claim; count allocation.
(test_09 makes the same argument for its flat counter, which this generalises.)

Why by source: a count alone says how many rooms an import allocated, never
WHY. The 2026-08-19 staging import measured 406 rooms for 1,516 notes with no
way to attribute them, which is what motivated the `source` tag (#1432). The
buckets mirror the closed set of atoms fixed in `crdt_channel.ex`:

    handshake / edit  — a `crdt_msg` frame, classified by `frame_class_b64/1`
    create_batch      — `crdt_create_batch` room enrollment (the web SPA path)
    unknown           — CrdtDoc.start_link's default: a caller that passed no
                        source. Not expected to move; it is the "someone added
                        an allocation path and forgot to tag it" tripwire, and
                        a silent zero here is a real signal, not filler.

The counter lives in `:persistent_term` (an `:atomics` ref, the same idiom
`FanoutPacer.test_drop_next/2` uses for e2e-armed counters) so it survives the
rpc process that arms it.

Both expressions are ONE logical Elixir line: `bin/engram rpc` takes the
expression as a single argv, and a one-liner cannot be reshaped by any newline
handling on the way through the release wrapper.
"""

from __future__ import annotations

from dataclasses import dataclass

from helpers.backend_rpc import backend_rpc

# Counter slot order. Must match the `case` in _ARM_EXPR and the field order of
# RoomStarts — all three are read positionally.
SOURCES = ("handshake", "edit", "create_batch", "unknown")

_ARM_EXPR = (
    ":persistent_term.put(:e2e_room_starts, :counters.new(4, [])); "
    ':telemetry.detach("e2e-room-starts"); '
    ':telemetry.attach("e2e-room-starts", [:engram, :crdt, :room_start], '
    "fn _, _, meta, _ -> "
    ":counters.add(:persistent_term.get(:e2e_room_starts), "
    "(case meta[:source] do :handshake -> 1; :edit -> 2; :create_batch -> 3; _ -> 4 end), 1) "
    "end, nil); "
    'IO.puts("armed")'
)

_READ_EXPR = (
    "c = :persistent_term.get(:e2e_room_starts); "
    "1..4 |> Enum.map(&:counters.get(c, &1)) |> Enum.join(\",\") |> IO.puts()"
)


@dataclass(frozen=True)
class RoomStarts:
    """Rooms allocated, per call path. Field order matches SOURCES."""

    handshake: int
    edit: int
    create_batch: int
    unknown: int

    @property
    def total(self) -> int:
        return self.handshake + self.edit + self.create_batch + self.unknown

    def __sub__(self, other: "RoomStarts") -> "RoomStarts":
        """Delta between two samples — the counter is cumulative per node, so a
        test measures its own window rather than everything since boot."""
        return RoomStarts(
            *(getattr(self, s) - getattr(other, s) for s in SOURCES)
        )

    def __str__(self) -> str:
        parts = ", ".join(f"{s}={getattr(self, s)}" for s in SOURCES)
        return f"{self.total} rooms ({parts})"


def arm_room_starts() -> None:
    """Install the telemetry handler. Call once before the measured window."""
    # backend_rpc raises on a non-zero exit, and this asserts the sentinel, so a
    # mis-staged probe fails loudly here rather than leaving a vacuously green
    # assertion at the end of the test.
    out = backend_rpc(_ARM_EXPR)
    assert "armed" in out, f"room-start counter did not arm: {out!r}"


def read_room_starts() -> RoomStarts:
    """Sample the cumulative per-source counts."""
    line = backend_rpc(_READ_EXPR).strip().splitlines()[-1]
    return RoomStarts(*(int(v) for v in line.split(",")))
