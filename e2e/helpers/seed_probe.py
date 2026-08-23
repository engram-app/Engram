"""Count genesis-seed outcomes on the backend node, by reason.

Companion to `room_probe`. That one answers "how many rooms did this import
allocate"; this one answers "did the import go through the CRDT create path at
all, and did each create's body seed roomlessly".

Why it exists: test_97 measured ZERO rooms for a 40-note first sync while the
2026-08-23 production import of the same shape measured 213. Zero is the
number a test reports both when the roomless path works perfectly AND when the
notes never touched the CRDT create path in the first place — e.g. they landed
over the REST batch push instead. Those two are opposite conclusions from an
identical reading, and only a seed count separates them.

The reasons mirror the closed set of atoms in `crdt_channel.ex`'s
`seed_outcome/1`; `seeded` is the success path and everything else names why a
body could not be applied detached.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from helpers.backend_rpc import backend_rpc

REASONS = (
    "seeded",
    "write_declined",
    "no_b64",
    "b64_not_binary",
    "not_markdown",
    "room_already_exists",
    "not_sync_update",
    "frame_decode_failed",
    "frame_unsafe",
    "apply_failed",
    "other",
)

_N = len(REASONS)
_LAST = _N
_ARMS = "; ".join(f":{r} -> {i}" for i, r in enumerate(REASONS[:-1], start=1))

# ONE logical Elixir line — see room_probe.py for why.
_ARM = (
    f":persistent_term.put(:e2e_seed, :counters.new({_N}, [])); "
    ':telemetry.detach("e2e-seed"); '
    ':telemetry.attach("e2e-seed", [:engram, :crdt, :genesis_seed], '
    "fn _, _, meta, _ -> :counters.add(:persistent_term.get(:e2e_seed), "
    f"(case meta[:reason] do {_ARMS}; _ -> {_LAST} end), 1) end, nil); "
    'IO.puts("armed")'
)

_READ = (
    "c = :persistent_term.get(:e2e_seed); "
    f'1..{_N} |> Enum.map(&:counters.get(c, &1)) |> Enum.join(",") |> IO.puts()'
)


@dataclass(frozen=True)
class Seeds:
    counts: dict[str, int] = field(default_factory=dict)

    @property
    def total(self) -> int:
        return sum(self.counts.values())

    def __sub__(self, other: "Seeds") -> "Seeds":
        return Seeds({r: self.counts[r] - other.counts[r] for r in REASONS})

    def __str__(self) -> str:
        live = {r: v for r, v in self.counts.items() if v}
        return f"{self.total} seeds {live or '{}'}"


def arm_seeds() -> None:
    out = backend_rpc(_ARM)
    assert "armed" in out, f"seed counter did not arm: {out!r}"


def read_seeds() -> Seeds:
    line = backend_rpc(_READ).strip().splitlines()[-1]
    values = [int(v) for v in line.split(",")]
    assert len(values) == _N, f"seed probe returned {line!r}"
    return Seeds(dict(zip(REASONS, values, strict=True)))
