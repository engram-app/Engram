"""Read every note's AUTHORITATIVE server text under a path prefix, in one rpc.

`GET /notes/*path` and MCP `get_notes` both go through `Notes.get_note/3`,
which returns `notes.content`: a FACADE that only moves at CRDT checkpoint
(docs/context/worker-reads-stale-content-facade.md). A convergence oracle on
the facade can call an edit "lost on the server" while the server holds it in
`crdt_state` + the `crdt_update_log` tail and has simply not checkpointed.

`Notes.authoritative_content/2` replays that tail onto the snapshot, so it
reflects every persisted CRDT write. It is not the hot read path (a decrypt
plus a Yjs rebuild per note); one rpc for a whole test folder is fine.

Paths are encrypted at rest, so the prefix filter runs after decrypt. The
result travels as base64 JSON on one line, so note bodies with newlines
cannot be reshaped by the release rpc wrapper.
"""

from __future__ import annotations

import base64
import json

from helpers.backend_rpc import backend_rpc

# ONE logical Elixir line (see room_probe.py for why).
_PROBE = (
    '{{:ok, vb}} = Ecto.UUID.dump("{vault_id}"); '
    "{{:ok, vr}} = Ecto.Adapters.SQL.query(Engram.Repo, "
    '"select user_id::text from vaults where id=$1", [vb]); '
    "u = Engram.Accounts.get_user!(hd(hd(vr.rows))); "
    "{{:ok, nr}} = Ecto.Adapters.SQL.query(Engram.Repo, "
    '"select id::text from notes where vault_id=$1 and deleted_at is null", [vb]); '
    "ids = List.flatten(nr.rows); "
    "{{:ok, notes}} = Engram.Repo.with_tenant(u.id, fn -> "
    "Enum.map(ids, &Engram.Repo.get(Engram.Notes.Note, &1)) end); "
    'pre = "{path_prefix}"; '
    "m = Enum.reduce(notes, %{{}}, fn n, acc -> "
    "case Engram.Crypto.maybe_decrypt_note_fields(n, u) do "
    "{{:ok, %{{path: p}}}} when is_binary(p) -> "
    "if String.starts_with?(p, pre) do "
    "case Engram.Notes.authoritative_content(u, n) do "
    "{{:ok, t}} -> Map.put(acc, p, t); "
    '{{:error, e}} -> Map.put(acc, p, "<authority error: " <> inspect(e) <> ">") end '
    "else acc end; "
    "_ -> acc end end); "
    'IO.puts("AUTHORITY\\t" <> Base.encode64(Jason.encode!(m)))'
)


def authoritative_notes(vault_id: str, path_prefix: str) -> dict[str, str]:
    """Live note path -> authoritative text, for notes under `path_prefix`."""
    out = backend_rpc(_PROBE.format(vault_id=vault_id, path_prefix=path_prefix), timeout=180)
    line = next((ln for ln in out.splitlines() if ln.startswith("AUTHORITY\t")), None)
    assert line, f"authority probe printed no result: {out[-500:]!r}"
    return json.loads(base64.b64decode(line.split("\t", 1)[1]))
