# The frontmatter fence rule: one Rust copy, one TS copy, one fixture table

_Last verified: 2026-11-11 (PR #2564, issue #1884)_

## Where it lives
- `native/engram_core/src/frontmatter.rs`: `split` and `split_after_bom`. Hand-written, no `regex`.
- Backend: `Engram.Notes.Frontmatter.split/1` (NIF `frontmatter_split`), the chunker, MCP outline, title/tags (`meta.rs`) and links (`links.rs`) all call it. Title/tags and links use `split_after_bom`, like the chunker.
- Web app: `splitFrontmatter` in `frontend/src/crdt/frontmatter-codec.ts`, a TS copy. Its only caller is genesis (note create/duplicate).
- One fixture table, `native/engram_core/fixtures/frontmatter_fence.json`, asserted by the Rust tests, `test/engram/native/frontmatter_fence_test.exs` and `frontend/src/crdt/frontmatter-fence-table.test.ts`. Add a case there, not in one suite.

## Why the web app is TS, not wasm
A wasm build of the Rust rule was tried and dropped (PR #2564 review). The only web caller is genesis, a TS fallback would still have to exist (no WebAssembly, CSP), so wasm bought no single source of truth: only a committed binary, a CI rebuild step, `'wasm-unsafe-eval'` in the CSP, and a bug (`TextDecoder` strips a leading BOM by default, so a BOM right after a fence vanished). The shared fixture table is what keeps the copies equal. Revisit only if a web caller needs Rust-only behaviour.

## The rule
- Open: byte 0, a line that is exactly `---`, LF or CRLF.
- Close: the first later line that is `---` plus optional spaces/tabs, then LF, CRLF or end of text. `---foo`, `----` and `---` plus other whitespace (U+180E) do not close.
- `---` right after the open is an empty block.
- `split` does not skip a BOM (the CRDT ingest must round-trip bytes). Read-only derivations use `split_after_bom`.

## What Obsidian does (read from app.js / worker.js of 1.12.7)
- `getFrontMatterInfo` (public API, used by `processFrontMatter`): open `/^---(\r?\n)/`, close `---(\r?\n|$)` at a line start. No BOM, no trailing blanks, `---foo` rejected.
- Metadata cache (Properties, worker.js): remark first rewrites CRLF to LF and strips a BOM, then opens on `---\n` and closes on the first `---` at a line start, so `---foo` DOES close there.
- Obsidian disagrees with itself; our rule sits between the two. To re-check: extract `~/.config/obsidian/obsidian-<ver>.asar` with `bunx @electron/asar extract` and search app.js for `getFrontMatterInfo`.

## Gotchas
- Before this, `meta.rs` closed on `---foo`/`----`, `links.rs` took any whitespace around the fences and missed a close at end of text, and the web TS opened only on `---\n`. Existing notes keep the title/tags/links derived under the old rules until edited: there is no version stamp for title/tags or links (only `@chunker_version`, `KeywordIndex @version`, payload). See `index-version-self-heal.md`.
- The plugin's `src/crdt/frontmatter-codec.ts` still opens only on `---\n` (no CRLF). Follow-up in the plugin repo: same rule, assert this fixture table.
