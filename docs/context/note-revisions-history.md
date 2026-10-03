# Note revisions: how version history is recorded (#1710)

**Trigger:** working on note history, restore (#1711), retention (#1712), DEK
rotation of history (#1713), or any code that writes `notes.content`.

## The model

- A version is one editing session by one actor. It closes when a different
  actor writes, after 10 idle minutes (`HISTORY_SESSION_GAP_MINUTES`), or on
  the note's first save after history shipped (that save keeps a `baseline`).
- Actors: `sync` (your editor, plugin and CRDT clients, all one actor), `mcp`,
  `api:<key_id>`, `import` (batch writes, origin `import`), `link_rewrite`,
  `maintenance`.
- The open version (`closed_at IS NULL`) has no stored text: it IS the note.

## The outbox

`Engram.Notes.Revisions.record_write/4` runs INSIDE each content write's
transaction, right after the fenced UPDATE succeeds. On a boundary it copies the
note's OLD `content_ciphertext` into the closing version's `pending_*` columns,
with no decrypt and no storage I/O. `Engram.Workers.FinalizeRevision` later
decrypts it (notes AAD), gzips it, re-encrypts it (revision AAD), stores it at
`revisions/<user>/<vault>/<note>/<rev>`, and clears the copy. The hourly
backstop is `Engram.Workers.FinalizeRevisionSweep` (`35 * * * *`).

## Traps

- **Hook AFTER the fenced write, never before.** A losing fenced write does not
  abort its transaction (the checkpoint's `{0, _}` commits; `lookup_and_write`
  retries in-transaction), so a pre-write hook records saves that never
  happened. `revisions_interleave_test.exs` pins this.
- **A new content-write path must call `Revisions.record_write/4` and
  `ContentCommit.after_commit/3`.** Three sites today:
  `CrdtCheckpoint.checkpoint_write/6` (actor `sync`), `Notes.do_rewrite_note/6`
  (actor from opts, default `api`), and `Notes.move_note` (id-keyed
  move/resurrect, only when the content hash changed; actor `sync` for the
  CRDT-socket genesis/resurrect callers, else the upsert opts). Missing one
  means no history for that writer.
- **`record_write/4` never fails the save.** Its rescue is total (every
  exception) and logs at error level with a redacted reason. Watch the log
  line, not the caller, to see history breaking.
- **New MCP write tools pass `@write_opts`**, or AI edits merge into your
  version. `HandlersWriteActorTest` counts the calls.
- **Never store Yjs snapshots as versions.** Yjs snapshot restore needs
  `gc: false`, which would make `crdt_state` grow without bound.
- **Prod is OFF** (`HISTORY_RECORDING`) until #1713 (rotation rewraps
  `pending_*` and blobs) and #1715 (the orphan sweep walks `revisions/`) ship.
- **The finalize lock matters.** Two concurrent finalizes without
  `Repo.advisory_lock!/1` each PUT with their own nonce, and only one nonce
  reaches the row.
