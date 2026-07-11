# CRDT note_id-collision corruption (2026-07-06)

_Last verified: 2026-07-06_

Prod data-corruption incident on the day the CRDT **id-keying cutover** shipped
(`#925` id-keyed doc_id + `#934` CRDT-state wipe, `release-v0.5.634/636`).
Symptom chain reported by the (single, pre-launch) user:

1. Edits made in the **web app never reached Obsidian** — not even via manual Sync.
2. Content **transferred between notes**; one note's content **overwrote others**.
3. In Obsidian, opening a note showed content for a few seconds then **blanked**.

Direction asymmetry: Obsidian→web worked; web→Obsidian was dead. That, plus
"reload survives" in the web (offline-first `y-indexeddb`) and the blanking
reaching Obsidian, meant the damage was **persisted server-side**, in `notes.content`.

## Root cause — two layers

### Amplifier (server, `lib/engram/notes.ex` `upsert_note`) — FIXED

`upsert_note` looks a note up by **path**; on a miss it looks up by **client_id**
and, if found, `move_note`s that row onto the new path (clearing the tombstone,
**crdt-merging** content, broadcasting `:moved` fleet-wide). `existing_by_client_id`
returned **any** note with that id — **live or tombstoned, at any path** — with no guard.

On the wire, "rename A→B (same id)" and "a *different* note that reuses A's id" are
**identical**: one `upsert` to path B carrying a note_id already live at path A.
So a client that emitted a duplicate note_id caused the server to **relocate +
merge** the live A row onto B — destroying A and bleeding its content across notes,
then fanning the collapse out to every device via the `:moved` broadcast.

**Fix (`efcb89dc`):** `move_note` may only relocate a **tombstoned** prior. A live
prior found by client_id (necessarily at a different path — the path lookup already
missed) is an id-collision → returned as `{:id_collision, live}` → `{:error,
:version_conflict}` with a distinct greppable log `note_id_collision_rejected`.
Real renames delete-first (tombstone) → hit the safe resurrect branch, unaffected.
A rename-race degrades to a transient conflict the client retries — safe, self-healing.

### Trigger (client, plugin `src/sync.ts` `pushFile`) — CHARACTERIZED, NOT yet fixed

`pushFile` mints a **fresh `uuid7()`** for any path not yet in its `NoteIdMap`
(`src/crdt/note-id-map.ts`) and sends it as the POST body `id`. On a **fresh vault**
this is fine — the plugin mints, the server adopts on insert, both agree. On an
**EXISTING vault upgraded to id-keying**, the server already holds ids for
pre-existing notes but the plugin's `NoteIdMap` starts empty, so the plugin mints
its **own** divergent ids until it *learns* the server's from a pull.

Divergence window symptoms (all observed): CRDT frames keyed by the plugin's minted
id → server `resolve_note_id` → `note_in_vault?` false → **`crdt_msg` dropped
`:not_found`** (this is what broke web→Obsidian live and produced the Loki drops);
and, pre-fix, a rename/move in that window could push a new path with a diverged id
that was live elsewhere → the server collapse above.

**Leading hypothesis for the *systematic* (many-note) collapse:** the plugin's first
upgraded sync learns ids only for notes in the **incremental `/sync/changes` feed**
(`sync.ts` ~L2559 `noteIdMap.set(c.path, c.id)`); pre-existing **unchanged** notes
are not in that feed, so their ids are never learned, the plugin mints divergent ids
for them on the next push/edit, and rename/move churn collapses them. `uuid7()`
collision was **ruled out** (74 bits of `crypto.getRandomValues`).

**Recommended plugin fix (needs runtime confirmation via the new logs first):** on the
id-keying upgrade, do a **full id reconciliation** — learn the server's id for *every*
existing note into `NoteIdMap` **before** minting or pushing anything. Only genuinely new
notes should mint. **Backend hook shipped in this PR:** `GET /sync/manifest` now returns
`id` on every note/attachment entry (`ManifestEntry.id`), so the plugin can populate the
whole path↔id map in one call on upgrade instead of guessing. The plugin also must not
send CRDT frames under an unconfirmed id, and must re-key the CRDT room if the backend
returns a different id than it guessed. Do NOT blind-fix without confirming the exact
learn-gap from prod logs / a repro.

## Why the tests missed it — and the fix

- **The suite codified the corruption as correct.** `notes_client_mint_test.exs` had
  `"moves a live id to a new path without double-counting"` asserting that pushing a
  **live** note's id at a new path MOVES it and `A.md` → `:not_found`. Removed.
- **`crdt_channel_test.exs:183`** asserts an unknown note_id **must** be dropped —
  correct server defense, but it *masks* that the client should never send one.
- **Every CRDT/sync test uses a FRESH vault** (in-session, unique ids). None seed a
  pre-existing vault and run the **upgrade/backfill** path — the entire failure class.

**Reusable pattern for upgrade/migration tests** (added in
`notes_client_mint_test.exs` describe `"existing-vault upgrade safety"`): seed
pre-existing **server** state, then drive the **upgraded client's divergent** behavior
and assert no corruption. Extend this for future cutovers.

## Observability fix (`a4b75cd7`)

The dropped-frame warning logged `doc_id` under the **`:path`** metadata key, which
`RedactFilter` scrubs to `[REDACTED]` — so during triage the note_ids of dropped
edits were unreadable, and drops carried **no user_id/vault_id** (unattributable).
Now: a well-formed doc_id logs under the un-redacted **`:note_id`** key + `user_id`/
`vault_id` attribution; a non-UUID doc_id (stale path-keyed client, maybe a real path)
stays under redacted `:path`. Loki gets it via the full-metadata FireLens JSON handler.

**Loki queries for this incident:**
```
{service_name="engram"} |= "dropped crdt_msg"                     # drops (now carry note_id + user_id)
{service_name="engram"} |= "note_id_collision_rejected"          # the guard firing (post-deploy)
```

## Recovery (NOT executed — needs approval; see recovery-plan section below)

Server `notes.content` is corrupted; the user's **local Obsidian vault (backed up
pre-blanking) is the clean source of truth**. Recovery is **Obsidian→server**, never
the reverse. Outline:
1. Keep the plugin disabled; confirm the vault backup is intact.
2. Deploy the server guard (this branch) so the rebuild can't re-collapse.
3. Wipe the corrupted CRDT state + rebuild `notes.content` from the clean local vault
   (fresh push), ensuring the plugin adopts server ids (clear `NoteIdMap` so it
   re-bootstraps cleanly, or land the plugin id-reconcile fix first).
4. Verify note count + spot-check content before re-enabling live sync.

## Files
- `lib/engram/notes.ex` — `upsert_note` id-collision guard (`{:id_collision, live}`)
- `lib/engram_web/channels/crdt_channel.ex` — `log_dropped/3` un-redacted note_id + attribution
- `test/engram/notes_client_mint_test.exs` — collision guard + upgrade-safety tests
- `test/engram_web/channels/crdt_channel_test.exs` — log-visibility + path-redaction tests
- Plugin (follow-up): `src/sync.ts` `pushFile` id-selection, `src/crdt/note-id-map.ts`
