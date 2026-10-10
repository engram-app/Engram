# Note revisions: how version history is recorded (#1710)

**Trigger:** working on note history, restore (#1711), retention (#1712), DEK
rotation of history (#1713), or any code that writes `notes.content`.

## The model

- A version is one editing session by one actor. It closes when a different
  actor writes, after 10 idle minutes (`HISTORY_SESSION_GAP_MINUTES`), or on
  the note's first save after history shipped (that save keeps a `baseline`).
- The gap runs from the open version's own `updated_at`, which each coalesced
  write bumps. Not `notes.updated_at`: renames and folder moves bump that.
- Text with no known author (first save, or history left without an open
  version) is kept as a `baseline`, never credited to the writer replacing it.
  Empty text is never kept: an open version over an empty note is dropped,
  not closed.
- Actors: `sync` (your editor, plugin and CRDT clients, all one actor), `mcp`,
  `api:<key_id>`, `link_rewrite`, `maintenance`, `system` (the welcome-note
  seed). `upsert_note/4` requires `actor:`; there is no default.
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
  `sync`), `Notes.do_rewrite_note/6` (actor from the required upsert opt), and
  `Notes.move_note` (id-keyed move/resurrect, only when the content hash
  changed; actor `sync` for the CRDT-socket relocate/resurrect callers, else
  the upsert opts). The finalize enqueue comes from
  `ContentCommit.enqueue_jobs/3` for the checkpoint and both upsert branches
  (the `:moved` one included), and, for the CRDT relocate/resurrect legs of
  `genesis_crdt_note/5`, from `finalize_moved_revision/2` after the
  transaction (enqueue only, no embed or link extraction). Each is gated on
  `Revisions.finalize?/3`: recording was on, the write was an update, and the
  content hash changed. Missing `record_write/4` means no history for that
  writer; missing the enqueue leaves the copy to the hourly sweep (10 to 70
  minutes).
- **Evaluate `Revisions.recording?/1` BEFORE the write transaction** and pass
  the boolean to `record_write/4` and `finalize?/3`. Inside the transaction the
  billing lookup would run under the vault row lock `Vaults.next_seq!` takes.
  A CRDT-created row holds the hash of empty text, not nil, so the checkpoint
  also skips finalize when the pre-write row had no text. The sweep enqueues
  `FinalizeRevision.job/2` regardless, so copies written before a switch-off
  still reach storage.
- **A copy that can never finalize is parked, not retried** (it will not
  decrypt, or the user has no usable DEK; a KMS unwrap failure stays
  transient). It gets
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
