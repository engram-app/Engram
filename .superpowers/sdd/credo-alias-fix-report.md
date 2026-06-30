# Credo AliasUsage Fix Report

## Summary

Fixed 28 `AliasUsage` findings (all `Engram.Notes.*` nested modules used
fully-qualified inside modules that never declared an alias) so that
`mix credo --strict` exits 0 under Elixir 1.17.3 (mise-pinned).

## Files Changed

### `lib/engram/notes/crdt_bridge.ex`

- Added `alias Engram.Notes.Frontmatter` after `import Bitwise` (3 sites fixed).
- Replaced 3 fully-qualified `Engram.Notes.Frontmatter.*` calls:
  - `project_doc/1`: `Engram.Notes.Frontmatter.project(...)` -> `Frontmatter.project(...)`
  - `ingest_plaintext/2`: `Engram.Notes.Frontmatter.split(...)` -> `Frontmatter.split(...)`
  - `ingest_plaintext/2`: `Engram.Notes.Frontmatter.parse(...)` -> `Frontmatter.parse(...)`

### `test/engram/notes/crdt_bridge_test.exs`

- The module already had `alias Engram.Notes.CrdtBridge` at the top.
- Replaced all 24 fully-qualified `Engram.Notes.CrdtBridge.*` calls with the
  short `CrdtBridge.*` form across 5 describe blocks + top-level tests using
  `replace_all` (pure mechanical rename, zero logic changes).

## Verification

- `mix credo --strict` (mise exec, Elixir 1.17.3): **exit 0, "found no issues"**
  (3537 mods/funs, 663 source files, 12.0 s analysis)
- `mix compile` (mise exec): clean, 2 files compiled, 0 warnings on our files
- `mix test test/engram/notes/crdt_bridge_test.exs` (mise exec): all green
- `mix format` applied to both changed files before commit
