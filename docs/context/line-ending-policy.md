# Context Doc: Note line-ending policy (LF-only in the CRDT doc)

_Last verified: 2026-11-12 (against the #697 and #2585 implementation, single-healer revision)_

## Status
Decided 2026-11-12 (Todd). Implementation in plugin PR Engram-obsidian#697 and backend PR Engram#2585.

## Decision
Markdown note text is LF-only inside the CRDT doc, the Relay model. One shared function per language converts `\r\n?` to `\n`:

- backend `Engram.Notes.LineEndings.to_lf/1` (`for_path/2` skips non-`.md`)
- web `frontend/src/lib/line-endings.ts` `toLf`
- plugin `src/crdt/line-endings.ts` `toLf`

Markdown only. Canvas, `.base` and attachments stay byte-exact.

### The single-healer rule
EXACTLY ONE actor removes CRs that are already in a doc: the server room process (one per note, so its heals are serialized).

- **On room open** (`CrdtPersistence.bind/3` -> `CrdtBridge.normalize_doc/1`), unconditionally, every open: the CR heal plus the fence lift, in one transaction. An old plugin can write CRs or a body fence back through the room at any time, and both checks are a scan of a body bind already reads, so there is no "already normalized" stamp.
- **On every live update** (`CrdtPersistence.update_v1/4`): `Native.yjs_inserts_cr/1` reads what the update inserted (O(update), never the body). If it inserted a `\r`, `CrdtBridge.heal_line_endings/1` runs as its own transaction, which is then appended and broadcast like any update.
- The heal: a `\r\n` loses its `\r` (a pure delete). A lone `\r` gets an `\n` inserted AT the CR first, then the CR deleted. Insert-first makes the LF's right origin the CR item, so it sorts before anything a device inserted right after that CR; delete-first let a concurrent append land before the LF. It also rewrites raw frontmatter spans that hold a CR (O(frontmatter), no ops when clean).

**Every other writer converts only its INCOMING text** and never emits an op on a CR already in the doc:

- server REST/MCP/web/batch writes: `maybe_merge_crdt` converts with `for_path`, then diffs with `lf_view: true` (`CrdtBridge.diff_into_text/3`): the diff runs against the LF VIEW of the body and maps back to raw UTF-16 offsets. A view newline that came from a CRLF maps to its `\r`, so an edit next to it never splits the pair; a deletion that spans a line break takes the raw CR with it, which is fine (a delete is idempotent).
- the live-room deliver, the backfill seed worker, the web genesis seed, the plugin seed and merge3 inputs: convert the incoming text, nothing else.

**Why one healer:** a lone-CR heal is a delete plus an insert. Deletes are idempotent across actors (both delete the same Y item); inserts are not. Two actors healing the same lone CR, or a writer re-healing a CR the room already healed in the tail (a REST write diffing against a stale snapshot, review MED 2), leave two line breaks. A classic-Mac file then gets every line break doubled.

## Why
- Obsidian/CodeMirror 6 saves LF everywhere and splits on `/\r\n?|\n/` (codemirror/state `change.ts`, DefaultSplit).
- CM counts a line break as 1 position, so keeping CRLF needs O(n) offset mapping per edit (codemirror/dev#961).
- The Yjs author says use `\n` only (yjs/y-codemirror.next#35).
- Relay normalizes in `src/diskText.ts` after a CRLF merge base caused conflicts (No-Instructions/Relay commit 9a5a42fe).
- Etherpad's `cleanText` does the same.

## Failed Approaches / Dead Ends
Keep CRLF in the doc and convert between the editor and the doc (the first version of Engram-obsidian#697). Its review found:
- a lone-`\r` drift loop
- CRLF spreading into LF notes
- an O(n) cost per keystroke
- conflict copies from a CRLF merge base

## Costs accepted
- One rewrite per CRLF note on its next sync, plus one disk write per device and one embed job. The job costs no tokens: the chunker already converts with `LineEndings.to_lf/1` (`Engram.Parsers.Markdown.parse/3`) and chunks are reused.
- Users who keep CRLF in git see one whole-file diff.
- A REST/MCP/web write into a doc that still holds CRs keeps them (only its own edit is LF) until the room next heals that doc, on open or on a live update.
- A note holding a lone CR re-chunks once: the chunker now converts lone CRs too.
- Unopened notes stay CRLF until a future backfill. The read-side CRLF tolerance (Rust fence rule, chunker, outline) must stay until that backfill ships as a DataMigration with its kill switch OFF.

## Gotchas
- `ingest_plaintext` is path-agnostic: `lf_view` is opt-in, and conversion happens in the caller (`for_path`), so a `.canvas`/`.base` doc diffs raw and lands byte-exact.
- Healing CRs anywhere but the room (a pre-ingest strip, a plugin-side lone-CR heal) reintroduces the doubled line break.
- Missing any one entry point causes mixed-ending files or conflict copies.
- CRLF notes cannot be counted in SQL: bodies are encrypted and `content_hash` is keyed. Counting needs an in-app per-tenant job or plugin first-sync telemetry.

## References
- Engram-obsidian#697 (plugin), Engram#2585 (backend)
- `docs/context/crdt-lineage-doubling.md`
