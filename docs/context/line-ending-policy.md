# Context Doc: Note line-ending policy (LF-only in the CRDT doc)

_Last verified: 2026-11-12 (against the #697 and #2585 implementation)_

## Status
Decided 2026-11-12 (Todd). Implementation in plugin PR Engram-obsidian#697 and backend PR Engram#2585.

## Decision
Markdown note text is LF-only inside the CRDT doc, the Relay model. One shared function converts `\r\n?` to `\n`, once, at ingest:

- plugin `seedContentInto`
- the merge3 inputs
- disk text before the `keepDiskFrontmatter` comparison
- server `Engram.Notes.LineEndings.to_lf/1` (`for_path/2` skips non-`.md`), called from `maybe_merge_crdt` (every REST/MCP/web write) and the live-room deliver
- the `normalize_doc` heal on room open: fence lift (deletes exactly the fence range) plus one small delete per body CR, in one transaction. It runs on EVERY open, with no "already normalized" stamp: an old plugin can write CRs or a body fence back through the room at any time.
- plugin `liftBodyFence` on editor open (the live binding's `healOnOpen`): the same fence lift plus a delete of each CRLF pair's CR. A lone CR is left to the server, which replaces it with LF; two devices both inserting that LF would merge to two.
- a write into a doc that still holds CRs first gets the same per-CR strip, then the diff, so a concurrent edit between two CRs is not undone.

Markdown only. Canvas, `.base` and attachments stay byte-exact.

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
- One rewrite per CRLF note on its next sync, plus one disk write per device and one embed job. The job costs no tokens: the chunker already strips CR (`markdown.ex:113`) and chunks are reused.
- Users who keep CRLF in git see one whole-file diff.
- Unopened notes stay CRLF until a future backfill. The read-side CRLF tolerance (Rust fence rule, chunker, outline) must stay until that backfill ships as a DataMigration with its kill switch OFF.

## Gotchas
- Converting in `ingest_plaintext` without the `markdown_path?` gate rewrites `.canvas`/`.base` files.
- Missing any one entry point causes mixed-ending files or conflict copies.
- CRLF notes cannot be counted in SQL: bodies are encrypted and `content_hash` is keyed. Counting needs an in-app per-tenant job or plugin first-sync telemetry.

## References
- Engram-obsidian#697 (plugin), Engram#2585 (backend)
- `docs/context/crdt-lineage-doubling.md`
