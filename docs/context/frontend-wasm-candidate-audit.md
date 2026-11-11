# Context Doc: Rust/WASM candidate audit (web app + plugin)

_Last verified: 2026-11-11_

## Status
Audit complete. Read-only pass over origin/main on 2026-11-11. Nothing here was benchmarked by us; the numbers quoted are the plugin's own or published figures.

## What This Is
Which web-app and plugin logic is worth moving into Rust/WASM, which is not, and the build pattern to use if we do. Written so nobody repeats the audit.

## What ships today
- The web app loads no WASM.
- `native/engram_core` is used only by the backend NIF and by the `wasm_guard` CI link check.
- The plugin ships its own ~1 KB Rust core: plain `extern "C"`, no wasm-bindgen, the `.wasm` is committed and inlined into `main.js`, and CI rebuilds it and compares.
- Plugin's own numbers: FNV hash is 1.0-1.4x faster than JS; native `toBase64` beats WASM base64 by about 10x.

## DO
- **Frontmatter fence split.** The same logic lives three times: backend `native/engram_native/src/frontmatter.rs`, web `frontend/src/crdt/frontmatter-codec.ts`, plugin `src/crdt/frontmatter-codec.ts`. The reason is correctness, not speed. TS opens a fence only on `---\n`; Rust also accepts `---\r\n`. The web copy claims "ported verbatim" but is 127 lines against the plugin's 192 (the plugin fence logic matches the web copy). Pair with #1884. Hand-write the scan; do not pull in the `regex` crate (hundreds of KB).

  **Outcome (decided 2026-11-11, merged in #2564).** The rule was consolidated once in Rust (`native/engram_core/src/frontmatter.rs`) for the backend NIF callers (frontmatter.rs, meta.rs, links.rs). The web app was deliberately NOT moved to WASM: its only caller is genesis (note create/duplicate), the TS fallback would keep a second copy anyway, and WASM cost a binary, a CI rebuild step, a CSP loosening (`'wasm-unsafe-eval'`) and a BOM-stripping bug (`TextDecoder` strips U+FEFF by default; needs `ignoreBOM: true`). Instead the web TS split reads the same shared golden fixture as the Rust and Elixir tests, so drift fails a test. Rule: `docs/context/frontmatter-fence-rule.md`. Plugin CRLF follow-up: engram-app/Engram-obsidian#696. Stored title/tags/links self-heal: #2570.

  **Lesson:** a WASM port only pays when it REMOVES the TS copy; if a fallback keeps the TS copy, share a fixture table instead.

## MAYBE
- Title / tags / link extraction: only if clients must derive them offline.
- Envelope crypto: only if client-side encryption becomes a product decision.

## NO, with reason
- **YAML parse**: would be a third rule set. The backend reference is YamlElixir.
- **Reading-mode markdown to HTML**: `unified` is ~37 KB gz; a Rust markdown WASM is hundreds of KB (e.g. satteri 673 KB gz). The cost is building the JS AST that React needs anyway.
- **yjs to yrs/ywasm**: ~350 KB gz vs 24 KB, slower per transaction, and breaks y-codemirror and y-indexeddb.
- **Diff / 3-way merge**: cost is string copying; backend `text_diff.rs` is a different algorithm.
- **Compression (#1887)**: use `CompressionStream`.
- **Hashing / base64**: measured, no win (see above).
- **Search**: server-side.
- **CM6 editor decorations and Lezer**: frequent small calls across the boundary; WASM loses.

## Build pattern (if a candidate is approved)
- Core logic in `native/engram_core`, plus a thin wasm32 layer.
- Committed `.wasm` with rebuild-and-compare CI (as the plugin does).
- Loader: esbuild binary loader (plugin) or Vite `?init` (web).
- Async load, known-answer self-check at startup, JS fallback if either fails.
- No wasm-pack, no wasm-bindgen.

## Gotchas
- Duplicated parsers drift: see `docs/context/consolidation-drops-undocumented-tolerances.md` (CRLF frontmatter).

## References
- `native/engram_core`, `native/engram_native/src/frontmatter.rs`
- `frontend/src/crdt/frontmatter-codec.ts`
- Plugin repo: `src/crdt/frontmatter-codec.ts`
- Issues #1884, #1887
