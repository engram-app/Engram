# Embed Less Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop paying Voyage and Qdrant dense storage for text nobody searches by meaning (encoded blobs, drawing data, frontmatter, data dumps), while keeping all of it findable by keyword.

**Architecture:** The Rust chunker strips more blob shapes from indexed text. Each chunk gets a `kind` (`prose | data | frontmatter | drawing`); only `prose` chunks get a dense vector, the rest are sparse-only points. `.canvas` and `.base` notes index sparse-only. A counter by kind sizes each lever in prod. One chunker version bump makes every note self-heal through the existing `index_versions` data migration.

**Tech Stack:** Rust NIF `native/engram_native` (chunker.rs), Elixir indexing (`lib/engram/indexing.ex`), PromEx.

**Spec:** user decisions 2026-10-19 in session (no vault spec); evidence `engram-workspace/reports/2026-10-18-qdrant-eval/prod-measure.md` (7,687 frontmatter points = 1.7%), `large-notes-audit.md` (359 single-section 1-2.7 MB dumps). Storage plan Task 12 (`2026-10-18-qdrant-storage-migration.md`) is folded in here.

## Global Constraints

- Nothing is deleted from the note; only the indexed text changes. Every stripped or sparse-only byte stays in `notes.content`.
- Keyword search must still find: frontmatter keys and values, Excalidraw text elements, `.canvas`/`.base` text, and exact tokens (hashes, ids, error codes) inside data chunks. Only base64 and hex BLOBS leave the sparse index too (as today's base64 rule).
- Bump `@chunker_version` (`lib/engram/parsers/markdown.ex:23`) exactly once on this branch, from 3 to 4. Existing notes heal via `DataMigrations.IndexVersions`; no operator step. Reused points are matched by fingerprint (`indexing.ex` ~1016), so unchanged prose chunks do not re-embed.
- The dense/sparse fingerprint already distinguishes a sparse-only point (`fingerprint_prefix/1`, indexing.ex ~1085); a chunk flipping kind must not reuse a point of the wrong shape.
- Never charge twice: a chunker-version rebuild stays the existing unmetered maintenance path.
- Metric labels: closed enums only, never user/vault/note ids.
- Backend commands under `mise exec --`; Rust tests with `cargo test` inside `native/engram_native` only for the chunker crate (one run per change). No em dashes. No version bumps of the app. Signed conventional commits.

## Review Focus

1. A prose note with one embedded PEM certificate keeps every prose chunk dense and byte-identical (no re-embed), and the cert's lines leave the index. Task 1.
2. A short hex-looking word (`deadbeef`, a 7-char git sha) and a long URL survive stripping. Task 1.
3. A note that is ONLY frontmatter is still searchable by keyword after frontmatter goes sparse-only, and `note_language/1` still works. Task 2.
4. A real prose paragraph containing a few numbers is never classified `data`. Task 3.
5. After the version bump, a note whose chunks are unchanged reuses every point (zero embedder calls). Task 2.

---

### Task 1: Strip wrapped base64 and hex blobs

**Files:**
- Modify: `native/engram_native/src/chunker.rs` (`strip_blobs`, `encoded`, ~359-392)
- Test: chunker unit tests in the same file

**Interfaces:** `strip_blobs/1` additionally removes (a) a run of 3+ consecutive lines that are each 40-120 chars of the base64 alphabet and together pass `encoded/1`, including PEM `-----BEGIN ...-----`/`-----END ...-----` armour lines around them; (b) a hex run `[0-9a-fA-F]{64,}` (sha256 and longer, hex dumps with no separators). Runs shorter than these thresholds are kept.

- [ ] **Step 1: Failing tests:** a PEM cert block (64-char lines) inside prose is removed, prose kept; a MIME base64 attachment (76-char lines) removed; a 128-char hex string removed; a 40-char git sha, `deadbeef`, a long URL and a long file path are kept; a markdown table of short words is kept.
- [ ] **Step 2: Run** `cd native/engram_native && cargo test chunker`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS, plus the existing `pathological_notes_stay_under_10x` test.
- [ ] **Step 5: Commit** `feat(chunker): strip wrapped base64 and hex blobs`.

### Task 2: Chunk kinds, sparse-only frontmatter, version bump

**Files:**
- Modify: `native/engram_native/src/chunker.rs` (`Chunk` gains `kind`), the NIF struct/encoder that hands chunks to Elixir, `lib/engram/parsers/markdown.ex` (`@chunker_version 4`), `lib/engram/indexing.ex` (plan entries: a non-prose chunk gets no dense vector even on a dense pass; `embed_texts/1` excludes it; fingerprint uses the sparse prefix for it)
- Test: `test/engram/indexing_chunk_kind_test.exs`, chunker unit tests

**Interfaces:**
- Rust `Chunk.kind: &'static str` in `prose | data | frontmatter | drawing`; Elixir chunk maps carry `:kind` (string). Frontmatter chunks are `frontmatter`. Everything else is `prose` in this task (Task 3 and 4 add `data` and `drawing`).
- In `indexing.ex`, a dense pass embeds only `kind == "prose"` chunks; others become sparse-only points in the SAME note. Voyage token metering counts only embedded chunks.

- [ ] **Step 1: Failing tests:** a note with frontmatter + 2 prose sections on a dense pass calls the embedder with exactly 2 texts and writes 3 points (frontmatter point has no `dense`); keyword search finds a frontmatter value; a frontmatter-only note writes 1 sparse-only point and is found by keyword; reindexing the same note after the version bump with unchanged content reuses every point (zero embedder calls); metered tokens equal the 2 prose chunks' tokens.
- [ ] **Step 2: Run** `mise exec -- mix test test/engram/indexing_chunk_kind_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.** Bump `@chunker_version` to 4 here, once.
- [ ] **Step 4: Run** the new file plus `test/engram/indexing*`, `test/engram/parsers/*`, `test/engram/workers/embed_note*`, `test/engram/data_migrations/*index_versions*`, and `cargo test chunker`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(indexing): sparse-only frontmatter chunks`.

### Task 3: Data-like chunks go sparse-only

**Files:**
- Modify: `native/engram_native/src/chunker.rs` (classify each body chunk)
- Test: chunker unit tests, `test/engram/indexing_chunk_kind_test.exs`

**Interfaces:** `classify(text) -> "prose" | "data"`. `data` when the chunk is mostly not words: fewer than 35% of its whitespace-separated tokens are dictionary-shaped words (2+ letters, letters only, optional trailing punctuation), measured over chunks of at least 200 bytes. Shorter chunks are `prose`. Fenced code blocks are `prose` (code is searched by meaning). Covers minified JSON, CSV/TSV rows of numbers, log lines dominated by timestamps/ids, number tables.

- [ ] **Step 1: Failing tests:** minified JSON (2 KB) -> data; a 40-row numeric CSV -> data; 30 log lines of `2026-10-19T05:14:49.0863647Z id=... status=200` -> data; an English paragraph with dates and figures -> prose; a German and a Cyrillic paragraph -> prose (letters are Unicode letters); a fenced Elixir code block -> prose; a markdown table of words -> prose.
- [ ] **Step 2: Run** `cargo test chunker`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cargo test chunker` and `mise exec -- mix test test/engram/indexing_chunk_kind_test.exs`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(chunker): data-like chunks are keyword-only`.

### Task 4: Excalidraw drawing data, canvas and base

**Files:**
- Modify: `native/engram_native/src/chunker.rs` (Excalidraw: drop fenced `json` / `compressed-json` blocks under the `## Drawing` heading; keep `## Text Elements`), `lib/engram/indexing.ex` `prepare_index` (`.canvas` and `.base` paths: every chunk sparse-only)
- Test: `test/engram/indexing_exclusions_test.exs`, chunker unit tests

**Interfaces:** the note path (decrypted, already in hand at index time) decides `.canvas`/`.base`; Excalidraw is detected by the `excalidraw-plugin` frontmatter key or a `.excalidraw.md` path.

- [ ] **Step 1: Failing tests:** an Excalidraw note's drawing JSON yields no chunk while its text elements are found by keyword and embedded; a `.canvas` note writes only sparse-only points and calls the embedder zero times; a `.base` likewise.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the new file plus `test/engram/indexing*`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(indexing): skip drawing data, keyword-only canvas and base`.

### Task 5: Counter by kind

**Files:**
- Modify: `lib/engram/prom_ex/indexing.ex` (or the existing indexing PromEx plugin), `lib/engram/indexing.ex` (emit at commit)
- Test: `test/engram/prom_ex/indexing_kind_test.exs`

**Interfaces:** counter `engram_prom_ex_index_points_written_total{kind, dense}`: `kind` in `prose | data | frontmatter | drawing | canvas | base`, `dense` in `true | false`, incremented per point written (reused points are not counted).

- [ ] **Step 1: Failing test:** indexing a note with 1 frontmatter + 2 prose + 1 data chunk emits frontmatter/false 1, prose/true 2, data/false 1.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(metrics): index points written by kind`.
