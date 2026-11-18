"""Count which WRITE ROUTE carried files under a path prefix to the backend.

Backs test_77's transport claim ("a bulk first sync lands over socket-native
`crdt_create`, never as per-note REST upserts") and test_107's folder-op claim
("a folder rename is ONE `folder_op`, nothing per file") with a count instead
of a wall-clock proxy. The old proxy ("1,000 notes in 120s") could not tell the
two apart on a shared runner: host contention moved the same sync from ~15s to
>120s, which is also roughly what the per-note REST fallback costs.

Same idiom as `room_probe`: a `:counters` ref in `:persistent_term` fed by
telemetry handlers attached over `bin/engram rpc`. Both handlers ride events
Phoenix ALREADY emits, so no backend code exists for the test's sake:

    crdt_create        `[:phoenix, :channel_handled_in]`, event "crdt_create"
    folder_op          `[:phoenix, :channel_handled_in]`, event "folder_op"
    rest_upsert        `[:phoenix, :router_dispatch, :stop]`, NotesController
                       :upsert (`POST /notes`, the per-note REST write)
    attachment_upload  same event, AttachmentsController :upload
    attachment_rename  same event, AttachmentsController :rename

All but `folder_op` are scoped to `prefix` so unrelated session traffic (e.g.
test_26's oversized note, which re-POSTs and 413s on every sweep) is not
attributed to the caller. A `folder_op` frame names folder ids, not paths, so it
is counted vault-wide; only test_107 and test_108 turn the switch on, and the suite is
serial.

A telemetry handler that raises is DETACHED silently, after which its slot
reads 0, and 0 is exactly the passing value for `rest_upsert`. So the read
also reports whether both handlers are still attached, and `read_routes`
refuses to return a vacuous zero.
"""

from __future__ import annotations

from dataclasses import dataclass

from helpers.backend_rpc import backend_rpc

_CH_ID = "e2e-routes-channel"
_HTTP_ID = "e2e-routes-http"
_CH_EVENT = "[:phoenix, :channel_handled_in]"
_HTTP_EVENT = "[:phoenix, :router_dispatch, :stop]"


def _arm_expr(prefix: str) -> str:
    # ONE logical Elixir line, see room_probe.py for why. `Map.get` (not
    # `m.params["path"]`) because Access on a non-map or a struct (an unfetched
    # body_params) raises, which would detach the handler. Raw attachment
    # uploads carry `path` in the query string, so uploads read `conn.params`.
    p = f'"{prefix}"'
    in_pfx = f"(fn x -> is_binary(x) and String.starts_with?(x, {p}) end)"
    return (
        ":persistent_term.put(:e2e_routes, :counters.new(5, [])); "
        f'Enum.each(["{_CH_ID}", "{_HTTP_ID}"], &:telemetry.detach/1); '
        f"in_pfx = {in_pfx}; "
        "bump = fn i -> :counters.add(:persistent_term.get(:e2e_routes), i, 1) end; "
        "mp = fn x -> if is_map(x), do: x, else: %{} end; "
        f':telemetry.attach("{_CH_ID}", {_CH_EVENT}, '
        "fn _, _, m, _ -> pr = mp.(m[:params]); cond do "
        'm[:event] == "crdt_create" and in_pfx.(Map.get(pr, "path")) -> bump.(1); '
        'm[:event] == "folder_op" -> bump.(3); '
        "true -> :ok end end, nil); "
        f':telemetry.attach("{_HTTP_ID}", {_HTTP_EVENT}, '
        "fn _, _, m, _ -> bp = mp.(m.conn.body_params); ps = mp.(m.conn.params); "
        "case {m[:plug], m[:plug_opts]} do "
        '{EngramWeb.NotesController, :upsert} -> if in_pfx.(Map.get(bp, "path")), do: bump.(2); '
        '{EngramWeb.AttachmentsController, :upload} -> if in_pfx.(Map.get(ps, "path")), do: bump.(4); '
        '{EngramWeb.AttachmentsController, :rename} -> if in_pfx.(Map.get(bp, "old_path")), do: bump.(5); '
        "_ -> :ok end end, nil); "
        'IO.puts("armed")'
    )


_READ_EXPR = (
    "c = :persistent_term.get(:e2e_routes); "
    "att = fn ev, id -> Enum.any?(:telemetry.list_handlers(ev), &(&1.id == id)) end; "
    "IO.puts(Enum.join(Enum.map(1..5, &:counters.get(c, &1)) ++ ["
    f'att.({_CH_EVENT}, "{_CH_ID}"), '
    f'att.({_HTTP_EVENT}, "{_HTTP_ID}")], ","))'
)


@dataclass(frozen=True)
class Routes:
    crdt_create: int
    rest_upsert: int
    folder_op: int
    attachment_upload: int
    attachment_rename: int

    def __str__(self) -> str:
        return (
            f"crdt_create={self.crdt_create} rest_upsert={self.rest_upsert} "
            f"folder_op={self.folder_op} attachment_upload={self.attachment_upload} "
            f"attachment_rename={self.attachment_rename}"
        )


def parse_routes(line: str) -> Routes:
    """Parse the probe's `<5 counts>,channel_attached,http_attached` line."""
    parts = line.strip().split(",")
    assert len(parts) == 7, f"route probe returned {line!r}"
    ch_ok, http_ok = parts[5:]
    assert ch_ok == "true" and http_ok == "true", (
        f"route probe handler detached (channel={ch_ok}, http={http_ok}): a raising "
        "telemetry handler is dropped silently, so its count would read a vacuous 0"
    )
    return Routes(*(int(n) for n in parts[:5]))


def arm_routes(prefix: str) -> None:
    """Install the counters. Call before the measured window; re-arming resets."""
    assert '"' not in prefix and "\\" not in prefix, f"unsafe prefix {prefix!r}"
    out = backend_rpc(_arm_expr(prefix))
    assert "armed" in out, f"route counter did not arm: {out!r}"


def read_routes() -> Routes:
    return parse_routes(backend_rpc(_READ_EXPR).strip().splitlines()[-1])
