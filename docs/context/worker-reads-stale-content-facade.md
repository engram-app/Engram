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

## Instance 3: user-facing reads, and the write_note erase (2026-10-25, #2248)

`Notes.get_note/3` and `get_note_by_id/3` used to keep the facade "because
staleness self-heals". It does not self-heal for an AI agent: MCP `get_notes`
right after a user typed served the old text, and a `write_note` of that text
after a checkpoint folded the user's edit diffed it away. Both helpers now read
the row and its tail in ONE statement (`with_tail/1`) and, only when the tail is
non-empty, resolve the body with the feed's `resolve_one/4` (same tolerances)
and re-derive `content_hash`/`title`/`tags` from it. An empty tail costs
nothing extra. The rebuild emits `[:engram, :notes, :read_rebuild]`.

The returned `content_hash` is the hash of exactly the text served (unlike the
sync feed, whose hash stays the row's). MCP `write_note` takes it back as an
optional `base_hash` and compares it against the AUTHORITY's text inside
`rmw_note/5`, not the row's stored hash: a user edit still in the tail leaves
the row's hash unchanged, so a row compare would pass the erase.

CRDT internals that need the stored row (fold snapshot + tail themselves,
compare against what they wrote) call `get_note_row_by_id/3`.

## Rule of thumb

If a worker's *output* is keyed on content-derived values (hmacs, hashes,
extracted links) **and** it can run in the window between a CRDT write and
its checkpoint, it must read `authoritative_content`, not the facade.
User-facing reads go through `get_note/3` / `get_note_by_id/3`, which already
serve the current text.
