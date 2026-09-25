"""Count which WRITE ROUTE carried notes under a path prefix to the backend.

Backs test_77's transport claim — "a bulk first sync lands over socket-native
`crdt_create`, never as per-note REST upserts" — with a count instead of a
wall-clock proxy. The old proxy ("1,000 notes in 120s") could not tell the two
apart on a shared runner: host contention moved the same sync from ~15s to
>120s, which is also roughly what the per-note REST fallback costs.

Same idiom as `room_probe`: a `:counters` ref in `:persistent_term` fed by
telemetry handlers attached over `bin/engram rpc`. Both handlers ride events
Phoenix ALREADY emits, so no backend code exists for the test's sake:

    crdt_create  — `[:phoenix, :channel_handled_in]`, event "crdt_create"
    rest_upsert  — `[:phoenix, :router_dispatch, :stop]`, NotesController
                   :upsert (`POST /notes`, the per-note REST write)

Both are scoped to `prefix` so unrelated session traffic (e.g. test_26's
oversized note, which re-POSTs and 413s on every sweep) is not attributed to
the caller.

A telemetry handler that raises is DETACHED silently, after which its slot
reads 0 — and 0 is exactly the passing value for `rest_upsert`. So the read
also reports whether both handlers are still attached, and `read_routes`
refuses to return a vacuous zero.
"""

from __future__ import annotations

from dataclasses import dataclass

from helpers.backend_rpc import backend_rpc

_CH_ID = "e2e-routes-crdt-create"
_REST_ID = "e2e-routes-rest-upsert"


def _arm_expr(prefix: str) -> str:
    # ONE logical Elixir line — see room_probe.py for why. `Map.get` (not
    # `m.params["path"]`) because Access on a non-map or a struct (an unfetched
    # body_params) raises, which would detach the handler.
    p = f'"{prefix}"'
    bulk = f"(fn x -> is_binary(x) and String.starts_with?(x, {p}) end)"
    return (
        ":persistent_term.put(:e2e_routes, :counters.new(2, [])); "
        f'Enum.each(["{_CH_ID}", "{_REST_ID}"], &:telemetry.detach/1); '
        f"in_bulk = {bulk}; "
        f':telemetry.attach("{_CH_ID}", [:phoenix, :channel_handled_in], '
        "fn _, _, m, _ -> "
        'if m[:event] == "crdt_create" and is_map(m[:params]) and '
        'in_bulk.(Map.get(m[:params], "path")), '
        "do: :counters.add(:persistent_term.get(:e2e_routes), 1, 1) end, nil); "
        f':telemetry.attach("{_REST_ID}", [:phoenix, :router_dispatch, :stop], '
        "fn _, _, m, _ -> "
        "if m[:plug] == EngramWeb.NotesController and m[:plug_opts] == :upsert "
        "and is_map(m.conn.body_params) and "
        'in_bulk.(Map.get(m.conn.body_params, "path")), '
        "do: :counters.add(:persistent_term.get(:e2e_routes), 2, 1) end, nil); "
        'IO.puts("armed")'
    )


_READ_EXPR = (
    "c = :persistent_term.get(:e2e_routes); "
    "att = fn ev, id -> Enum.any?(:telemetry.list_handlers(ev), &(&1.id == id)) end; "
    "IO.puts(Enum.join([:counters.get(c, 1), :counters.get(c, 2), "
    f'att.([:phoenix, :channel_handled_in], "{_CH_ID}"), '
    f'att.([:phoenix, :router_dispatch, :stop], "{_REST_ID}")], ","))'
)


@dataclass(frozen=True)
class Routes:
    crdt_create: int
    rest_upsert: int

    def __str__(self) -> str:
        return f"crdt_create={self.crdt_create} rest_upsert={self.rest_upsert}"


def parse_routes(line: str) -> Routes:
    """Parse the probe's `crdt,rest,ch_attached,rest_attached` line."""
    parts = line.strip().split(",")
    assert len(parts) == 4, f"route probe returned {line!r}"
    crdt, rest, ch_ok, rest_ok = parts
    assert ch_ok == "true" and rest_ok == "true", (
        f"route probe handler detached (crdt_create={ch_ok}, rest_upsert={rest_ok}) "
        "— a raising telemetry handler is dropped silently, so its count would "
        "read a vacuous 0"
    )
    return Routes(int(crdt), int(rest))


def arm_routes(prefix: str) -> None:
    """Install the counters. Call before the measured window; re-arming resets."""
    assert '"' not in prefix and "\\" not in prefix, f"unsafe prefix {prefix!r}"
    out = backend_rpc(_arm_expr(prefix))
    assert "armed" in out, f"route counter did not arm: {out!r}"


def read_routes() -> Routes:
    return parse_routes(backend_rpc(_READ_EXPR).strip().splitlines()[-1])
