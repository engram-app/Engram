"""Read and stage one note's SERVER Y.Doc via `bin/engram rpc`.

The plugin's disk and the REST row are both projections; neither shows where
the frontmatter actually lives in the doc. A note whose fence sits in the body
Y.Text (the old-plugin / pre-#1645 damaged shape) and a healthy note project to
the same text, so only the doc can tell "properties as properties" from
"properties as body text".

`read_server_doc` rebuilds the doc the way a room's bind does (snapshot plus
tail) but WITHOUT `normalize_doc`, so it never heals what it reads.

The staging helpers write through a room (`CrdtRoom.update_doc`), so the change
is persisted and delivered like any other server-side edit. A room's bind runs
`normalize_doc`, which lifts a body fence into the map; `pin=True` keeps the
room alive (an observer process holds it) so no rebind heals the damage until
`release_room`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from helpers.backend_rpc import backend_rpc, vault_user_expr

_FM = "Engram.Notes.CrdtBridge"


@dataclass(frozen=True)
class ServerDoc:
    order: list[str]  # raw `frontmatter_order`, duplicates kept
    values: dict[str, str]  # JSON-encoded values, as stored
    body: str  # the `content` Y.Text
    state_vector: str  # base64; changes iff any client minted an op

    @property
    def unique_order(self) -> list[str]:
        return list(dict.fromkeys(self.order))


def _elixir_str(s: str) -> str:
    # JSON string escapes (\\r, \\n, \\", \\\\, \\uXXXX) are valid Elixir string
    # escapes. `#{` would interpolate, so refuse it rather than escape it.
    assert "#{" not in s, f"fixture text must not contain '#{{': {s!r}"
    return json.dumps(s)


def read_server_doc(vault_id: str, note_id: str) -> ServerDoc:
    nid, vid = _elixir_str(note_id), _elixir_str(vault_id)
    out = backend_rpc(
        vault_user_expr(vault_id)
        # `crdt_state_ciphertext` is a VIRTUAL field (it lives in note_bodies),
        # so `Repo.get` leaves it nil and the doc reads empty. Select it the way
        # `LineageAudit` does.
        + "import Ecto.Query; "
        "{:ok, d} = Engram.Repo.with_tenant(u.id, fn -> "
        f"n = from(x in Engram.Notes.Note, where: x.id == ^{nid}) "
        "|> Engram.Notes.NoteBody.select_note([:id, :dek_version, :crdt_state_ciphertext, :crdt_state_nonce]) "
        "|> Engram.Repo.one!(); "
        "{:ok, st} = Engram.Crypto.decrypt_crdt_state(n, u); "
        f"{{:ok, d}} = {_FM}.doc_from_state(st); "
        f"Engram.Notes.CrdtPersistence.replay_tail(d, u, {nid}, {vid}); d end); "
        f"{{o, v}} = {_FM}.frontmatter_of(d); "
        'IO.puts("DOC\\t" <> Jason.encode!(%{order: o, values: v, '
        f"body: {_FM}.body_of(d), "
        "sv: Base.encode64(Yex.encode_state_vector!(d))}))"
    )
    line = next((ln for ln in out.splitlines() if ln.startswith("DOC\t")), None)
    assert line, f"server doc probe returned {out!r}"
    raw = json.loads(line.removeprefix("DOC\t"))
    return ServerDoc(raw["order"], raw["values"], raw["body"], raw["sv"])


def _in_room(vault_id: str, note_id: str, fun: str, pin: bool) -> None:
    nid = _elixir_str(note_id)
    pin_expr = (
        "pin = spawn(fn -> Yex.Sync.SharedDoc.observe(pid); "
        "receive do :e2e_release -> :ok after 300_000 -> :ok end end); "
        f":global.re_register_name({{:e2e_room_pin, {nid}}}, pin); "
        if pin
        else ""
    )
    out = backend_rpc(
        vault_user_expr(vault_id)
        + f"{{:ok, pid}} = Engram.Notes.CrdtRegistry.ensure_started(u.id, {_elixir_str(vault_id)}, {nid}); "
        + pin_expr
        + f":ok = Engram.Notes.CrdtRoom.update_doc(pid, {fun}); "
        'IO.puts("staged")'
    )
    assert "staged" in out, f"room staging did not run: {out!r}"


def damage_server_doc(vault_id: str, note_id: str, fence: str) -> None:
    """Rewrite the doc into the old-plugin damaged shape in ONE transaction:
    every frontmatter key and the order removed, `fence` (the block's raw text,
    fences included) prepended to the body. Pins the room so it stays damaged."""
    fun = (
        "fn d -> m = Yex.Doc.get_map(d, \"frontmatter\"); "
        'a = Yex.Doc.get_array(d, "frontmatter_order"); '
        't = Yex.Doc.get_text(d, "content"); '
        "Yex.Doc.transaction(d, fn -> "
        "Enum.each(Map.keys(Yex.Map.to_map(m)), &Yex.Map.delete(m, &1)); "
        "n = length(Yex.Array.to_list(a)); "
        "if n > 0, do: Yex.Array.delete_range(a, 0, n); "
        f"Yex.Text.insert(t, 0, {_elixir_str(fence)}) end) end"
    )
    _in_room(vault_id, note_id, fun, pin=True)


def append_order_key(vault_id: str, note_id: str, key: str) -> None:
    """Append `key` to `frontmatter_order` again: the merged result of two
    concurrent fence lifts (server normalize + a plugin seed)."""
    fun = f'fn d -> Yex.Array.push(Yex.Doc.get_array(d, "frontmatter_order"), {_elixir_str(key)}) end'
    _in_room(vault_id, note_id, fun, pin=False)


def release_room(note_id: str) -> None:
    """Drop the pin and stop the room, so the next open binds a fresh room and
    runs `normalize_doc`. Safe to call when nothing is pinned."""
    nid = _elixir_str(note_id)
    backend_rpc(
        f"case :global.whereis_name({{:e2e_room_pin, {nid}}}) do "
        "p when is_pid(p) -> send(p, :e2e_release); _ -> :ok end; "
        f"Engram.Notes.CrdtRegistry.terminate_room({nid}); "
        'IO.puts("released")'
    )


def bind_room(vault_id: str, note_id: str) -> None:
    """Start the room (its bind runs `normalize_doc`) without observing it."""
    out = backend_rpc(
        vault_user_expr(vault_id)
        + f"{{:ok, _}} = Engram.Notes.CrdtRegistry.ensure_started(u.id, {_elixir_str(vault_id)}, {_elixir_str(note_id)}); "
        'IO.puts("bound")'
    )
    assert "bound" in out, f"room bind did not run: {out!r}"
