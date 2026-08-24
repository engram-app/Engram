"""Count notes whose stored CRDT doc holds MORE THAN ONE Yjs client.

Backs the 2026-08-23 first-sync double-write: against a real vault (server
"health local test v10", 316 notes) EVERY note's stored Y.Doc held exactly two
clients, each with a clock equal to half the final character count — the whole
document inserted twice, once per client. Server bytes were exactly 2x the file
on disk; disk was never wrong; opening a note converged it back to 1x, which is
why the corruption was invisible from the client.

Why client count and not content length: a length check needs the disk bytes to
compare against, and the two insertions do not always land end-to-end. When they
interleave the text is still 2x but is not a clean `X+X`, so a
"first half == second half" test misses it — that is exactly how the production
sample first read as "17 of 60 doubled" when the real answer was all of them.
The client count is structural and catches both shapes.

A healthy note written by one device has ONE client. A second client means a
second independent lineage reached the server, which is the defect regardless of
how the two copies happen to be ordered in the text.

The state vector's leading varint IS the client count, so this reads one byte
rather than decoding the whole structure. That is valid below 128 clients; a
vault that somehow exceeded that would under-report, and 128 distinct writers on
one note is already a far louder bug than this probe is looking for.

## `path_prefix` is not optional in practice — pass it (2026-08-24)

The e2e vault fixtures (`sync_vault_id`, `vault_a`) are `scope="session"`, so
ONE vault is shared by the whole suite and its notes persist across tests. An
unscoped sample therefore answers a question no caller is asking: it counts
notes written by ~110 other tests, and **a note legitimately edited by two
devices has two Yjs clients**. 34 e2e tests drive a second device, so the
unscoped count has a permanent non-zero floor that no plugin fix can move.

That floor is what made `test_97`/`98`/`100` fail on every CI run from the day
they merged (#1455) — never once green — with counts that did not budge across
plugin changes (12/135 and 12/146 in back-to-back runs; `test_98` contributed 11
fresh notes and 0 new multi-client ones). Scoping to the caller's own prefix is
what makes the assertion measure the fixture the caller actually controls.

Filtering happens in Elixir AFTER decrypting each note, not in SQL: `path` is
encrypted at rest, so there is no column to `LIKE` against.
"""

from __future__ import annotations

from dataclasses import dataclass

from helpers.backend_rpc import backend_rpc

# ONE logical Elixir line: `bin/engram rpc` takes the expression as a single
# argv, so a one-liner cannot be reshaped by newline handling in the release
# wrapper (same constraint room_probe.py documents).
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
    "pairs = Enum.map(notes, fn n -> "
    "{{:ok, st}} = Engram.Crypto.decrypt_crdt_state(n, u); "
    "c = if st do {{:ok, d}} = Engram.Notes.CrdtBridge.doc_from_state(st); "
    ":binary.first(Yex.encode_state_vector!(d)) else 0 end; "
    "p = case Engram.Crypto.maybe_decrypt_note_fields(n, u) do "
    "{{:ok, %{{path: pp}}}} when is_binary(pp) -> pp; "
    '_ -> "<undecryptable>" end; '
    "{{c, p}} end); "
    'pre = "{path_prefix}"; '
    'scoped = if pre == "", do: pairs, '
    "else: Enum.filter(pairs, fn {{_, p}} -> String.starts_with?(p, pre) end); "
    "counts = Enum.map(scoped, &elem(&1, 0)); "
    "Enum.each(Enum.filter(scoped, fn {{c, _}} -> c > 1 end), fn {{c, p}} -> "
    'IO.puts("LINEAGE_MULTI\\t" <> Integer.to_string(c) <> "\\t" <> p) end); '
    "IO.puts(Enum.join([length(counts), Enum.count(counts, &(&1 > 1)), "
    'Enum.max(counts, fn -> 0 end)], ","))'
)


@dataclass(frozen=True)
class Lineages:
    notes: int
    multi_client: int
    max_clients: int

    def __str__(self) -> str:
        return (
            f"{self.multi_client}/{self.notes} notes hold >1 Yjs lineage "
            f"(worst: {self.max_clients} clients)"
        )


def read_lineages(vault_id: str, path_prefix: str = "") -> Lineages:
    """Sample live notes in `vault_id`, restricted to `path_prefix`.

    PASS A PREFIX. The vault is session-scoped and shared by the whole suite,
    so an unscoped sample counts other tests' notes — including legitimately
    two-writer ones — and can never reach zero. See the module docstring.

    Raises if the probe misfires.
    """
    out = backend_rpc(_PROBE.format(vault_id=vault_id, path_prefix=path_prefix))
    lines = out.strip().splitlines()
    # Print WHICH notes are multi-client, so a failure names the offending
    # paths instead of only a count — the count alone cost a debugging cycle.
    for ml in (ln for ln in lines if ln.startswith("LINEAGE_MULTI\t")):
        print(ml)
    parts = lines[-1].split(",")
    assert len(parts) == 3, f"lineage probe returned {lines[-1]!r}"
    return Lineages(*(int(p) for p in parts))
