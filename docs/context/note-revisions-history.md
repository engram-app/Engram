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
- **A new content-write path must call `Revisions.record_write/4` inside its
  transaction, and enqueue `FinalizeRevision` after commit.** Three
  `record_write/4` sites today: `CrdtCheckpoint.checkpoint_write/6` (actor
  `sync`), `Notes.do_rewrite_note/6` (actor from opts, default `api`), and
  `Notes.move_note` (id-keyed move/resurrect, only when the content hash
  changed; actor `sync` for the CRDT-socket relocate/resurrect callers, else
  the upsert opts). The finalize enqueue comes from
  `ContentCommit.after_commit/3` for the checkpoint and both upsert branches
  (the `:moved` one included), from the bulk `Oban.insert_all` in
  `batch_upsert_side_effects`, and, for the CRDT relocate/resurrect legs of
  `genesis_crdt_note/5`, from `finalize_moved_revision/2` after the
  transaction (enqueue only, no embed or link extraction). Each is gated on a
  changed content hash. Missing `record_write/4` means no history for that
  writer; missing the enqueue leaves the copy to the hourly sweep (10 to 70
  minutes).
- **`FinalizeRevision.new_for_note/2` returns `:skip` while recording is
  off.** `Enqueue.enqueue/2` drops it, the batch path filters it. The sweep
  uses `FinalizeRevision.job/2`, which ignores the switch, so copies written
  before a switch-off still reach storage.
- **A copy that can never decrypt is parked, not retried.** It gets
  `finalize_failed_at` and is skipped by the job and the sweep from then on,
  so it cannot block the note's later versions. Find them with
  `finalize_failed_at IS NOT NULL`; the error log line names the revision id.
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
