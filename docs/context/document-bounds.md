# Per-document bounds: what one note can cost, and where it stops

Why: a prod task has ~1 GB RAM and one dirty CPU scheduler. Notes go to 10 MB.
The 2026-10-06 audit (after #1885) measured what a single hostile or just
very large note could cost, path by path. This is the list of caps that came
out of it. Rule that shaped them: a cap may drop DERIVED data (graph edges,
tags, parsed properties); it never drops the note, its text, or its search
and indexing. Notes of any size still save, index and read.

## What is capped, and what happens past it

| Path | Cap | Past it | Before (10 MB worst) |
|---|---|---|---|
| Note size | 10 MB in `Notes.upsert_note/4` (`:too_large`) and, for live edits, `CrdtBridge.fits?/2` before the apply (`note_too_large`) | write refused, nothing changes. Sync step 1 and reads still work | `replace_text`, append, section edits, link rewrite and CRDT frames had no check |
| `replace_text` | result sized (hit count x delta) before the string is built | `10MB` error | 1M hits x 1 KB = a 1 GB string |
| `get_notes` frontmatter check | `[ \t]*`, not `\s*` | n/a | 28.6 s on 200 KB of blank frontmatter lines |
| Frontmatter YAML fallback | 32 KB (`Frontmatter` `@yaml_max_bytes`) | block kept as text, `parse_status` reason `frontmatter_too_large` | 7-9 s on a 300 KB block, every save |
| Chunks | `max(2000, len/512)` (`chunker.rs` `budget/1`) | tiny sections coalesce up to 2 KB; every byte still indexed | 1.7M chunks, 466 MB, ~13k Voyage calls |
| Stored links | first 20,000 by position (`Parser.extract/1`), `[:engram, :links, :truncated]` | later edges not stored | 713 MB for 1.67M links |
| Tags | 1,000 distinct (`meta.rs` `MAX_TAGS`), frontmatter first | later tags not stored | 1.16M tags, ~55 MB of hashes per Qdrant point |
| Outline (MCP sections) | 100k headings+lines+ranges (`outline.rs`), see `native-nifs.md` | `too_complex` | ~2.5 GB comrak arena |
| `get_notes` | 4 MB of content per call, first note always whole | later notes answer "fetch in its own call" | 20 x 10 MB ~ 1 GB |

`Parser.extract_all/1` is uncapped on purpose: the rename rewrite must change
every occurrence or leave it dangling, and stores nothing.

## Known residuals (measured or reasoned, NOT fixed)

- **Link rewrite is O(edits x note size).** `Rewriter.apply_edits!` measured
  3 s for 1,000 edits on 1 MB, 26 s for 10,000, 107 s for 10,000 on 4 MB:
  y_ex resolves each UTF-16 offset by scanning inside one big block. The
  tempting fix, one diff for all edits, is wrong: it deletes and reinserts
  everything between the first and last edit and clobbers a concurrent
  editor's text in that span. Bounded by the Oban timeout (5 min, 3 attempts),
  no extra memory, needs thousands of links to ONE renamed target in one note.
  Real fix is in y_ex (offset cache) or batching by touched block.
- **`Parser.extract_all` on a rename holds every link as BEAM terms** (the
  713 MB case) for a note with ~1M links to scan. Same trigger as above.
- **Attachments buffer whole files** (#1886): ~50 MB per upload, the risk is
  concurrent uploads, not one file.
- **Live-edit cap unit is UTF-16, not bytes**: an all-CJK note can reach ~30 MB
  of UTF-8 before the doc cap trips. It bounds growth, it does not mirror the
  byte cap. The frame cap (5 MB) is separate and unchanged.
- **Notes already over 10 MB** (if any exist) refuse every live edit,
  including deletes that would shrink them. Not probed in prod.
- **Cold-loading a 10 MB room** outran the 3 s room-free apply budget in the
  test env (debug NIFs). Not measured in prod.
- Not measured: y_ex memory under adversarial updates (item count, not text
  size); catch-up page of one 10 MB note x slots.
- Account export loads every note row of a vault at once
  (`accounts/export/streamer.ex`), out of per-document scope.

## How to extend

Measure first with the shapes in `docs/context/native-nifs.md` (1 MB and
10 MB of tight lists, `#` lines, dense inline, blank lines, `%%` + code
spans), and cap the RESULT, not just the parse: the outline parse was already
bounded per segment and its result was not. Release NIF numbers only: test-env
NIFs are debug builds. Put a failing test first; the caps above each have one.
