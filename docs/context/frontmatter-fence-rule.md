# The frontmatter fence rule: one copy, in Rust, shared with the web app

_Last verified: 2026-11-11 (branch `refactor/shared-frontmatter-fence`, issue #1884)_

## Where it lives
- `native/engram_core/src/frontmatter.rs`: `split` and `split_after_bom`. Hand-written, no `regex` (the wasm stays under 1 KB).
- Backend: `Engram.Notes.Frontmatter.split/1` (NIF `frontmatter_split`), the chunker, MCP outline, title/tags (`meta.rs`) and links (`links.rs`) all call it. Title/tags and links use `split_after_bom`, like the chunker.
- Web app: `native/web_wasm` builds `frontend/src/crdt/frontmatter-fence.wasm` (committed). `frontend/src/crdt/frontmatter-fence.ts` loads it async with a self-check; `splitFrontmatterTs` in `frontmatter-codec.ts` is the fallback.
- One fixture table, `native/engram_core/fixtures/frontmatter_fence.json`, asserted by the Rust tests, `test/engram/native/frontmatter_fence_test.exs` and `frontend/src/crdt/frontmatter-fence.test.ts`. Add a case there, not in one suite.

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
- The wasm must stay panic-free: one slice index pulls in core's panic formatting and doubles the module. Use `get(..)`.
- `web_wasm` is empty off wasm32 (`#![cfg(target_arch = "wasm32")]`), so host workspace builds skip it. It depends on `engram_core` without the `envelope` feature, so it needs no C toolchain (wasi-sdk).
- The CSP needs `'wasm-unsafe-eval'` in `script-src` (`lib/engram_web/csp.ex`, `frontend/public/_headers`), or the browser refuses to compile and the TS path runs.
- A JS string with a lone surrogate would reach the wasm as U+FFFD, so `fenceSplit` sends those to the TS path.
