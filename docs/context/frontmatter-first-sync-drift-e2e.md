# Context Doc: Reproducing frontmatter drift / false conflict copies in e2e (Engram#1928)

_Last verified: 2026-10-10_

## Status
Working repro. Fix in flight: backend PR #1930 (branch `fix/first-sync-fm-drift`), plugin Engram-obsidian#567.

## What This Is
How to make a first sync produce a frontmatter drift conflict copy on purpose, and how to see that copy at all.

## 1. The fixture must be a THREE-WAY disagreement
A drift copy needs all three renderings of the frontmatter to differ:

- raw bytes on disk
- plugin re-emit (eemeli `yaml`)
- backend re-emit (Ymlr, via `CrdtBridge.project_doc`)

Single-key fixtures almost never trip it:

- quoted wikilink alone: the plugin keeps raw
- `key:` (empty) or a long line alone: the backend keeps raw; catch-up logs "baseline-content row (echo/lagged)" and moves on

Real notes mix keys. Shapes confirmed three-way:

- `up: "[[Home]]"` plus `status:`
- `tag: "#project"` plus `tags: [a, b]`
- `status: ~`
- `answer: "yes"`
- `aliases: ["[[A]]", "[[B]]"]`
- `title: "Meeting: kickoff" # comment`

Verify a new shape cheaply before writing an e2e:

1. Plugin side: in a scratch `bun test` file, build the genesis update with `ProviderRegistry.encodeGenesisUpdate`, apply it with `applyRemoteUpdate`, and export the re-emitted bytes.
2. Backend side: via tidewave `project_eval`, `Engram.Notes.CrdtBridge.doc_from_state/1` then `project_doc/1` on those bytes.
3. Raw, plugin output and backend output must all differ.

## 2. You cannot find the conflict copy by scanning disk afterwards
`writeDriftConflictCopy` stamps the copy as synced but never pushes it. Manifest reconcile then trashes it about 1s later ("Reconcile: server-deleted -> trashed"). That line is `loki_ship: false`, so it is invisible in prod Loki too. Filed as Engram#1931.

Detect it live instead: install an `app.vault.on('create', ...)` listener over CDP before the sync and record created paths.

Gotcha: end the CDP evaluate expression with `; true`. Otherwise CDP tries to serialize the returned EventRef and fails with "Object reference chain is too long".

## 3. test_100 never caught this
test_100 asserts the rewrite HAPPENS and fences only the lineage count. It never looks for new files, so it passed straight through this defect.

## Failed Approaches / Dead Ends
- Seq-cursor rewind (`setCatchupSeq`) to force catch-up over the pushed notes: unnecessary. The drift fires inside the first FullSync on its own, because pushes and catch-up interleave.
- Single-key fixtures (see section 1): green no matter what the code does.

## Gotchas: local stack
Correction to workspace `docs/context/local-crdt-e2e-repro.md`: the main checkout's `.env` `ENCRYPTION_MASTER_KEY` is not 32 bytes for the CI image. Boot fails with "must decode to 32 bytes; got 48".

Fix: in the shell, export the runbook's CI key plus `CRDT_ENABLED=true CI_PG_PORT=5439`. Shell env overrides `--env-file .env`.

## References
- Regression test: `e2e/tests/test_101_first_sync_frontmatter_no_conflict.py` + `e2e/helpers/frontmatter_first_sync.py` (branch `fix/first-sync-fm-drift`, PR #1930)
- Red proofs: `test_102` + `tests/crdt/test_frontmatter_raw_precedence.py` on branch `test/frontmatter-fidelity-repro`
- Plugin fix: Engram-obsidian#567
- Issues: #1928 (drift copies), #1931 (unpushed copy trashed by reconcile), #1932
- Workspace runbook: `docs/context/local-crdt-e2e-repro.md`
