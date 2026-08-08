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
vault**, i.e. someone copies an existing vault's files into a fresh vault, so the plugin's
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

1. `classify_by_id/2` (via `existing_by_client_id/2`) asks "does this id exist?", but it is
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

> The `DO NOTHING` was a deliberate choice. See the comment above `do_bare_insert/6`: it
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

# Control, a FRESH id into the same new vault succeeds:
{:ok, _} = Notes.genesis_crdt_note(user, vb, Ecto.UUID.generate(), "A/Note.md", origin: "obsidian")
```

Same id at a *different* path fails identically: it is the id collision, not the path.

## Why it was undiagnosable from prod
Two silent catch-alls in `lib/engram_web/channels/crdt_channel.ex` collapsed every unmodelled
error into the string `create_failed` and logged nothing:

- `prepare_create/4` (batch path) ended in a bare `_ ->`
- the single-`crdt_create` path had `{:error, %Ecto.Changeset{}}` and `{:error, _reason}` arms
  that replied without logging

506 failures produced **zero** server-side explanation. Fixed on branch
`fix/crdt-create-silent-failure`. Both arms now log the underlying term with
`user_id`/`vault_id`/`doc_id`. The wire contract is unchanged; only the silence is gone.

Note the asymmetry that caused this: `log_entry_failure/2` (the rescue/exit path, same file)
carries the comment *"NOT a silent swallow: every occurrence is logged with the reason."* That
discipline was applied to the dramatic failure mode and missed on the boring one, which is the
one that actually fired.

## Why the test suite missed it
`e2e/tests/test_77_bulk_first_sync.py` covers a 1,000-note bulk first sync, but it writes notes
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
- **Crypto/KMS.** Prod runs AWS KMS, local runs `KeyProvider.Local`, but the bug reproduces on
  the Local provider, so the crypto class is not involved.
- **Base64 framing.** The plugin uses standard padded `btoa` (`src/crdt/wire.ts:13`), which
  `Base.decode64/1` accepts.

## The fix (shipped)
**Server-side re-mint, in `do_bare_insert` only.** `nil` on the post-insert re-fetch means "our
insert no-op'd AND no live row owns this path", so the conflict was on the id, not the path.
`remint_own_id/7` then decides, and it does **not** re-mint unconditionally:

- **Another vault of the SAME user** (the vault-copy case): mint a fresh v7 uuid and retry once (a
  `remint?` flag bounds the recursion). The row returns through the normal success path, so the
  real id reaches the client in the `crdt_create` ack's `doc_id` and in the REST body.
- **Another USER's row, or a genuine vanished-race**: unchanged, still the 422.

RLS is what makes the two cheap to tell apart, and it is the whole trick: the connection is scoped
to the current *user* while the lookups that already failed were scoped to the current *vault*. So
one extra unvaulted `Repo.exists?` by id, run only in this rare branch, answers "is this mine?"
without an RLS bypass and without a query on the hot path.

Four things made this the right shape, and they are worth preserving if this code is touched
again:

- **One leg, every caller.** `do_bare_insert` is shared by REST/MCP/web *and* `crdt_create`. A fix
  in `crdt_channel` would have left the REST path broken.
- **No plugin change, and old plugins are repaired too.** The client already handles an ack whose
  `doc_id` differs from the id it sent: `applyCrdtCreateAck` (`plugin/src/sync.ts`) remaps the
  note, transfers live keystrokes out of the orphaned mint doc, retires it, and reseeds the body;
  `pushFile` has the equivalent live adopt. A new error reason code (the original plan) would have
  fixed only plugins shipped after it.
- **The cross-tenant guard is deliberate, not collateral.** `notes_controller_test` "rejects a
  client-supplied id colliding with another user's note" asserts the 422, and its comment
  explicitly rejects "silently falling back to a server-minted id". A first cut of this fix
  re-minted unconditionally and that test caught it. Do not widen the re-mint to all collisions:
  a caller must not be able to probe or adopt another tenant's PK, and minting them a row off the
  back of a hijack attempt is not a favour worth doing.
- **The untargeted `ON CONFLICT DO NOTHING` stays.** It is load-bearing (see below).

Note the untargeted `ON CONFLICT DO NOTHING` stays. It is load-bearing (it dodges the
partial-index `conflict_target` fragment-matching footgun, and the transaction-abort class behind
the test_24 replay flake). The comment above it used to claim `notes_user_vault_path_v2` was the
only unique index a row could violate; the PK is the one it forgot.

**Tripwire:** `note id owned by another vault; re-minting <old> -> <new>` (category `sync`,
warning). A spike means clients are pushing ids from a vault they no longer sync to, which is
worth understanding even though the note now lands.

**Coverage:** `test/engram/notes_client_mint_test.exs` (REST leg) and
`test/engram/notes/genesis_crdt_note_test.exs` (crdt_create leg) both assert the note lands under
a new id and the owning vault is untouched. The `test_77` gap (a *new vault* whose notes carry
*pre-owned ids*) is now covered at the context layer; an e2e over the real change-vault UI flow is
still missing.

## Still open: where the reused ids come from
The server no longer loses notes, whatever the client sends, so this is no longer a data-loss
question. But the client half is **not** explained, and the obvious theory is wrong:

`SyncEngine.wipePerVaultState` **does** clear the note-id map on a vault change (`noteIdMap.clear()`,
in-place so `main.ts`'s shared instance is really cleared), and both vault-change paths route
through it: the explicit picker (`resetForVaultChange`) and the backstop
(`invalidateIfVaultChanged`). After that clear, a push mints fresh uuids, which cannot collide. So
"the change-vault path forgets to clear the id map" is **ruled out**; do not re-walk it.

What is still unproven is why the reported "Change vault -> create new vault -> sync" run produced
colliding ids at all. Getting that requires the reason logging in this same change to reach prod
and a repeat of the flow.

## Related
- `docs/context/worker-reads-stale-content-facade.md` (another `crdt_create`-adjacent trap
- `../../docs/context/crdt-wrong-mint-cross-file-overwrite.md` (workspace), the other
  id-identity failure class
