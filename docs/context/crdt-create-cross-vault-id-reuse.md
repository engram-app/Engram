# Context Doc: `crdt_create` fails for every note when a new vault reuses existing note ids

_Last verified: 2026-08-08_

## Status
Root cause proven with a minimal reproduction against local dev. Logging fix committed
(`fix/crdt-create-silent-failure`). The behavioural fix (server reason + plugin re-mint) is
NOT yet implemented.

## Symptom
A first-time full-vault sync into a **brand-new vault** fails for *every* note. The client logs,
once per note:

```
[client:crdt] crdt_create failed, enqueued for durable retry: <path> | Error: request failed: {"reason":"create_failed"}
```

Retries fail identically, burn their attempts, and the plugin eventually gives up:

```
[client:crdt] crdt_create dropped (max-attempts) without delivery: <note_id>
```

Observed in SaaS prod 2026-08-08: 513-note vault → 506 `crdt_create failed`, **304 notes
permanently dropped**. Server-side error count for the same window: **zero**.

## Precondition (why this is easy to miss)
It only fires when a new vault is populated with notes whose **ids already exist in another
vault** — i.e. someone copies an existing vault's files into a fresh vault, so the plugin's
NoteIdMap / frontmatter ids carry over. A new vault filled with genuinely new notes is fine.

## Root cause
`Repo.insert(..., on_conflict: :nothing)` is checked against one key and recovered against
another. When they disagree, the note falls through the gap.

In `lib/engram/notes.ex` `do_bare_insert/6`:

```elixir
case Repo.insert(changeset, on_conflict: :nothing) do
  {:ok, _} ->
    case Repo.one(lookup_query) do          # lookup_query is PATH-keyed, vault-scoped
      %Note{id: ^note_id} = inserted -> {:inserted, inserted, crdt}
      %Note{} = existing -> {:raced, existing}
      nil -> {:error, Ecto.Changeset.add_error(changeset, :path, "insert raced and vanished")}
    end
```

Sequence:

1. `classify_by_id/2` (via `existing_by_client_id/2`) asks "does this id exist?" — but it is
   **vault-scoped**. The id lives in the *old* vault, so the new vault gets `:none` → "brand new
   note, insert it".
2. `notes.id` is a **global** primary key. The insert collides with the old vault's row and
   `on_conflict: :nothing` silently turns the PK violation into `{:ok, _}`.
3. The recovery read (`lookup_query` = `note_by_path_query/3`) is keyed on **path_hmac**, scoped
   to the new vault → no row.
4. `nil` → `"insert raced and vanished"` changeset error → the channel's changeset arm replies
   the generic `create_failed`.

The insert conflicts on **id**; the recovery looks up by **path**. Cross-vault id reuse is exactly
the case where those two disagree.

> The `DO NOTHING` was a deliberate choice — see the comment above `do_bare_insert/6`: it
> "sidesteps the partial-index conflict_target fragment-matching footgun" of
> `notes_user_vault_path_v2`. A workaround for one index problem opened a hole around a
> different one. Any fix must keep the partial-index dodge.

## Reproduction (minimal, deterministic)
Against local dev via Tidewave:

```elixir
{:ok, user} = Accounts.create_user_with_password(email, "hunter2hunter2")
{:ok, va} = Vaults.create_vault(user, %{name: "Orig"})
{:ok, vb} = Vaults.create_vault(user, %{name: "Copy"})
id = Ecto.UUID.generate()

{:ok, _}     = Notes.genesis_crdt_note(user, va, id, "A/Note.md", origin: "obsidian")
{:error, cs} = Notes.genesis_crdt_note(user, vb, id, "A/Note.md", origin: "obsidian")
# => %{path: ["insert raced and vanished"]}

# Control — a FRESH id into the same new vault succeeds:
{:ok, _} = Notes.genesis_crdt_note(user, vb, Ecto.UUID.generate(), "A/Note.md", origin: "obsidian")
```

Same id at a *different* path fails identically — it is the id collision, not the path.

## Why it was undiagnosable from prod
Two silent catch-alls in `lib/engram_web/channels/crdt_channel.ex` collapsed every unmodelled
error into the string `create_failed` and logged nothing:

- `prepare_create/4` (batch path) ended in a bare `_ ->`
- the single-`crdt_create` path had `{:error, %Ecto.Changeset{}}` and `{:error, _reason}` arms
  that replied without logging

506 failures produced **zero** server-side explanation. Fixed on branch
`fix/crdt-create-silent-failure` — both arms now log the underlying term with
`user_id`/`vault_id`/`doc_id`. The wire contract is unchanged; only the silence is gone.

Note the asymmetry that caused this: `log_entry_failure/2` (the rescue/exit path, same file)
carries the comment *"NOT a silent swallow: every occurrence is logged with the reason."* That
discipline was applied to the dramatic failure mode and missed on the boring one — which is the
one that actually fired.

## Why the test suite missed it
`e2e/tests/test_77_bulk_first_sync.py` covers a 1,000-note bulk first sync — but it writes notes
with **freshly minted ids** into an **existing** vault. The failing case needs a *new vault* whose
notes carry *pre-owned ids*. No test constructs that state.

## Dead ends (do not re-investigate)
Ruled out with evidence during the 2026-08-08 investigation:

- **DB pool exhaustion.** Ecto queue-time p99 did spike 9.9ms → 224ms during the sync, but
  `entry_guard/2` logs raises and exits and produced **zero** lines. The spike was a *symptom* of
  500+ retries, not the cause.
- **Path validation.** Both validators (`notes.ex` `validate_path/1`, `crdt_channel.ex`
  `validate_create_path/1`) only reject blank paths. `&`, commas, parens are all fine.
- **Tuple-arity mismatch.** `genesis_insert_bare/6` returns `{:ok, note, :announce}`; it *is*
  correctly unwrapped to `{:ok, note}` at `notes.ex:771`.
- **Crypto/KMS.** Prod runs AWS KMS, local runs `KeyProvider.Local` — but the bug reproduces on
  the Local provider, so the crypto class is not involved.
- **Base64 framing.** The plugin uses standard padded `btoa` (`src/crdt/wire.ts:13`), which
  `Base.decode64/1` accepts.

## Fix shape (not yet implemented)
Two halves:

1. **Server** — when the insert no-ops and the path lookup returns `nil`, look the id up
   **globally**. If it belongs to a different vault, reply a distinct, actionable reason (e.g.
   `id_owned_by_other_vault`) rather than the generic `create_failed`. `"insert raced and
   vanished"` should be reserved for a genuine race.
2. **Plugin** — re-mint note ids when enrolling a vault whose ids are already owned elsewhere. A
   copied vault is a new vault; its notes need new identities.

Add an e2e or integration case covering *new vault + pre-owned ids* — the gap `test_77` leaves.

## Related
- `docs/context/worker-reads-stale-content-facade.md` — other `crdt_create`-adjacent trap
- `../../docs/context/crdt-wrong-mint-cross-file-overwrite.md` (workspace) — the other
  id-identity failure class
