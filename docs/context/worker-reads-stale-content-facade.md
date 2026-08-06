# A worker reads `note.content` right after a CRDT write and gets stale data

**Class of bug.** `note.content` (via `Crypto.maybe_decrypt_note_fields`) is a
**facade**, not the authority, once a note has a `crdt_state`. It only
materializes at CRDT checkpoint. Anything that writes through the CRDT path
(live edits, roomless persists, catch-up backfill) advances the real content
immediately but the facade lags until the next checkpoint. A background
worker that reads the facade in that window processes stale content.

`Engram.Notes.authoritative_content(user, note)` is the fix: it decrypts the
CRDT snapshot and replays the `crdt_update_log` tail, so it reflects writes
that haven't checkpointed yet. It's deliberately not the default read path —
it costs a decrypt + Yjs doc rebuild + tail query per call.

## Instance 1 — `NotesController.append/2`

The original motivating case. Append must read current content before
concatenating; reading the facade meant an append after a live edit could
silently drop the edit. Fixed by switching to `authoritative_content`.

## Instance 2 — link-extraction re-derives stale hmac edges (2026-08-05, PR #1280)

**Symptom.** `RewriteNoteLinks`'s roomless persist repairs a note's outbound
links (writes fresh content through the CRDT path, no checkpoint yet). A
second worker — link extraction, which recomputes `note_links` edges from
`note.content` — runs right after, reads the facade, re-derives the **old**
hmac edges from pre-repair content, and clobbers the just-repaired
`note_links` row back to dangling. The convergence test caught it red.

**Fix.** Link extraction now reads via `Notes.authoritative_content/2`
instead of the facade. Precedent: `NotesController.append/2` above; this is
the second caller.

**Known residual.** `EmbedNote` still reads the facade, so embeddings can
briefly index staler content than links between a rewrite and its checkpoint.
Self-heals at the next checkpoint. Accepted 2026-08-05 — revisit only if
search-freshness complaints show up.

## Rule of thumb

If a worker's *output* is keyed on content-derived values (hmacs, hashes,
extracted links) **and** it can run in the window between a CRDT write and
its checkpoint, it must read `authoritative_content`, not the facade.

Pure display/read paths (`Notes.get_note/3`) keep the facade on purpose —
that's the hot path and the staleness self-heals at checkpoint with no
persisted side effect to clobber.
