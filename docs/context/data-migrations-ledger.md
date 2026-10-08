# Data migrations ledger

_Last verified: 2026-10-06_

## The rule

A data migration that must reach existing rows is an `Engram.DataMigration`
module registered in `Engram.Workers.DataMigrationsRunner` `@migrations`. It is
never an operator command and never a one-off rpc (see "Upgrades require zero
operator action" in `AGENTS.md`). The runner runs at "boot" (Oban Cron
`@reboot`) and hourly (minute 33), on the `:maintenance` queue. Oban Cron
schedules only on the leader, so "boot" means when a node takes Cron
leadership: on a single node, every boot; on a multi-node fleet, a node that
boots while another holds leadership does not trigger a run. The worker's
`unique` (`period: 3000, states: :incomplete`) means two runs never overlap,
but a run that already completed never swallows the next one. Each pass runs one bounded slice of work for every
migration whose ledger row is not done. One migration raising does not stop the
others.

## The contract

- `name/0`, `version/0`, `run_pass/0`.
- Optional `enabled?/0` (default `true`). A disabled migration is skipped
  entirely: no pass, and its ledger row is not opened, alerted on or marked
  done. Use it for a kill switch under which the work would be a no-op (a pass
  that cannot succeed would otherwise page as stuck after 7 days). Disabled
  time is not stuck time: if the row is already open, every disabled run
  holds its clock (`DataMigrations.hold_clock/1` resets `opened_at` to now and
  clears `alerted_at`), so re-enabling after a long disable does not page; the
  7 days count from the last disabled run.
- Optional `reverify?/0` (default `false`). See "Re-verify" below.
- `run_pass/0` returns `:done` only when it found no work. Errors, users
  skipped mid DEK rotation and jobs still in flight are `:more`.
- `:done` means no row the backfill would process still needs work, checked
  against exactly those rows (the same scan and predicate the worker uses).
- Two kinds of unfixed row, treated oppositely:
  - Rows the worker can never SELECT (deleted notes, soft-deleted vaults, for
    `CrdtStateSeed` notes backed by a `crdt_update_log` tail) are not its work.
    They are excluded from both the done predicate and the enqueue set, or the
    migration could never close and would enqueue no-op jobs every hour.
  - Rows the worker selects but FAILS on (content that never decrypts, a codec
    rejection) keep the migration open. That is by design: a closed ledger must
    not hide an unfixed row. The cost is one cheap pass (and one vault's job)
    per hour, and the stuck-migration alert surfaces it.
- So the done predicate and the enqueue set both use the worker's own selection
  predicate, never a looser one; a pair with no selectable row is not enqueued.
- Readers handle every older format. The ledger only saves work, it is not a
  correctness gate.

## Versioning

Bump `version/0` to reopen a migration. `DataMigrations.done?/2` treats a stored
higher version as done, so a rollback to older code does not redo work. Only
`true` is cached (in `:persistent_term`). A done migration goes back to
not-done only through a code change (which restarts the node) or a re-verify
that finds work (`DataMigrations.reopen/2`, below), which drops the cache on
the node that ran it; other nodes keep their cached `true` until restart.

`IndexVersions` is the exception: its `name/0` embeds the chunker, keyword and
embed model versions, so bumping any of them is a new, not-done migration.

## Re-verify

A done migration is skipped, so rows that become work again afterwards (an
older node writing the old format during a rolling deploy or after a rollback,
or writes while the migration was disabled) are never picked up until a
version bump. A migration whose `reverify?/0` returns `true` gets its pass
re-run once a day: the runner job scheduled in the 04:00 UTC hour (the same
hour `ReconcileEmbeddings` re-checks `IndexVersions`). If that run is
deduped or fails, the day is not lost: any hourly run re-verifies a done row
whose last verification (`completed_at`, rewritten by every `:done`
re-verify) is over 25 h old (`DataMigrations.verified_before?/2`). `:done` calls
`mark_done/2` (idempotent; it re-closes a row another node reopened while this
node still cached `done?`); `:more` calls `DataMigrations.reopen/2` (clears
`completed_at`, restarts the stuck clock, drops this node's cached `done?`),
and the hourly passes take over until it closes again. Keep the pass cheap
enough to run daily. `EnvelopeFormat`'s is one EXISTS per user per column:
the `user_id` index narrows to the user's rows, but `octet_length` is not
indexed, so it reads each of those rows until a match (cheap at prod scale:
`octet_length` on a TOASTed bytea reads the TOAST pointer, not the value). `IndexVersions` predates this and
keeps its own check in `ReconcileEmbeddings`.

## Cross-tenant discovery

Use `DataMigrations.any_row?/1`. Never `skip_tenant_check: true` on the app
pool: FORCE RLS turns that into zero rows and the migration would close early
(#1349). `any_row?/1` uses the maintenance repo when enabled, else one query per
user inside that user's RLS context.

## Jobs without `unique`

If the backfill worker has no `unique` option, guard the enqueue with
`DataMigrations.jobs_in_flight?/1` so a running chain is not duplicated.

## Tests

`DataCase` resets the `done?` cache before every non-async test. A test that
touches `done?` must not be `async: true`, because the cache is node-global.

## Current migrations

| Name | Covers |
|---|---|
| `CrdtStateSeed` | Residue of the 2026-07-06 cutover that NULLed every `crdt_state`: each pass enqueues `BackfillCrdtState` for live-vault pairs holding a seedable note (kind note, not deleted, NULL state, no `crdt_update_log` rows) via `BackfillCrdtState.enqueue_missing/0`. A NULL-state note WITH a tail is excluded from both the enqueue and the done check, and the worker never seeds it: its real state is the un-checkpointed tail, and a snapshot seeded from content would be a second Yjs lineage that bind unions with it. Tail replay serves those notes. A selected note whose content never decrypts is a stuck row: it keeps the migration open until fixed. After each seed the worker evicts any resident room for the note (`CrdtRegistry.terminate_room/1`, no checkpoint), because a room bound before the seed holds an empty doc whose next edit would start a second lineage. Eviction is `:global`, so before EACH seed the worker checks every room is reachable (`Cluster.Readiness.rooms_reachable?/1`, after `:global.sync/0`): a single node always; a multi-node fleet only when its connected peers cover every `DNS_CLUSTER_QUERY` A record except its own IP, and an empty lookup (NXDOMAIN, timeout) counts as unreachable (with a role but no query, any peer). The first miss ends the batch with no further writes and no successor job; the migration stays open and the next pass starts over. If a tail row exists right after a kill, it logs `possible second lineage` (warning, with `note_id`). Restoring a soft-deleted vault enqueues `BackfillCrdtState` for it, since this migration may have closed while the vault was excluded. The worker runs on the `:crdt_backfill` queue (concurrency 1). |
| `EnvelopeFormat` | #1872 PR 3: every compressible DB envelope (`notes.content_ciphertext`, `notes.crdt_state_ciphertext`, `crdt_update_log`, `vault_index_states`, `vault_index_update_log`) off legacy format 0. Each pass enqueues `ReencodeEnvelopes` (`:crypto_backfill`, priority 3) for every user with a legacy row: `octet_length(nonce) = 12 AND octet_length(ct) > 16` (16 = tag only = empty plaintext, legitimately format 0; a 13-byte nonce is done whatever its codec), plus `dek_version >= 2` for the note body (a pre-T3.6 body's empty AAD has no compression policy). No liveness filter: soft-deleted notes and vaults are re-encoded too. The worker decrypts and re-encrypts under the same DEK and AAD, reading only the key, AAD id and the one ciphertext + nonce pair, and writes only ciphertext and nonce, CAS on the old ciphertext, so a concurrent edit wins and `updated_at`/`version`/`seq` never move. A `crdt_state` rewrite NULLs `crdt_head` via the trigger; `WarmCrdtHeads` re-warms it. No `RotationLock` (that 503s clients): each batch reloads the user and snoozes while a rotation holds the lock; that gate plus the CAS is the safety, not the queue (Oban OSS limits are per node). A crashed rotation keeps its lock, so after 60 snoozes (~1 h) the job cancels as `:rotation_locked` with a `:warning` naming the user, and the next pass re-enqueues it. A job works ~30 s, then enqueues its successor with its cursor (column + last id) before returning, so the chain is always in flight. One chain per user: `unique` on `user_id` over `available`/`scheduled`/`retryable` (not `executing`, so a job can insert its own successor) drops a duplicate enqueue, discovery skips a user whose job is `executing` (the guard is per user, so one pinned user never stalls the others), and a job that finds a newer in-flight job for its user (a Lifeline-rescued predecessor) cancels itself (`:superseded`). After a Lifeline rescue the hand-off can hit the unique conflict while the rescued predecessor cancels, leaving no chain for that user; the next hourly pass re-enqueues (up to ~1 h delay, no lost work, no false done). Per-user discovery inserts are not atomic and self-heal on the next pass. Each 200-id batch is cut into chunks of at most 8 MB of STORED bytes (`octet_length` probe; always at least one row, so a single huge note still progresses), each committed in its own tenant transaction, so memory and row-lock time are bounded by bytes, not row count. A row that never decrypts is logged (`:warning`, table and row id) and keeps the migration open. `enabled?/0` is `Envelope.compression_on?/0`: false under `ENVELOPE_COMPRESSION=false` or while any cluster node cannot read format 1 (`CompressionGate`); the worker cancels itself on the same decision, checked at job start and before every chunk; `reverify?/0` is true. Attachments and `note_revisions.pending_*` are not re-encoded. |
| `IndexVersions` | Every content-current note stamped with the current chunker, keyword and embed model versions. `ReconcileEmbeddings` does the rebuild. Once done it drops the version term and skips the keyword scan, except for one hour a day (04:00-04:59 UTC) that re-verifies: a rollback then roll-forward or a restored soft-deleted vault puts stale notes back without reopening it. See `index-version-self-heal.md`. |

## Pruned (2026-10-06)

Prod audit (4,338 live notes): legacy MD5 hashes 0, missing `basename_hmac` 0,
plaintext vault slugs 0, version-stale 0. These finished one-time backfills were
deleted, not ported; do not re-add them: `ContentHashHmac`
(`BackfillContentHashHmac`, `ContentHash.Backfill`), `NoteLinkHmacs`
(`BackfillNoteLinks`, `Links.Backfill`), `VaultSlugHmac`
(`Vaults.backfill_slug_hmacs/1`), and the operator worker `ReindexKeyword`.
There is no 32-char hash compatibility code: a legacy MD5 `content_hash` simply
never matches a fresh HMAC, so such a note reads as content-stale and re-embeds.
`vaults.slug` reads stay until the contract release. Recover the code from git history if a restore ever needs it.

## Stuck migrations

A pass that returns `:more` (or fails, `:error`) calls
`DataMigrations.note_open/2`, which stamps `opened_at` on the ledger row the
first time that version is seen unfinished. A version bump or a reopen resets
`opened_at` and `alerted_at`. If a migration is still open more than 7 days
after `opened_at`, the runner reports `data migration stuck`, at most once per
migration per 24 h (`alerted_at`): a `Sentry.capture_message/2` (migration,
version and `opened_at` in `extra`) plus an `:error` log line for Loki. The
explicit capture is required: `capture_log_messages` is off, so a
`Logger.error` alone never reaches Sentry.

`opened_at` measures one version's age only. The stored version never drops:
`note_open/2` keeps the higher one and `mark_done/2` is a no-op on a row at a
higher version, so during a rolling deploy an old node neither resets the
clock nor closes the newer version's work. A failure before a pass runs (the
`done?/2` read, `name/0`, `version/0`) leaves the ledger untouched.

Review: find the rows the migration's done predicate still matches (its
`any_row?` query), then fix them or explain why they can never be done, and
adjust the migration so the predicate stops matching them.

## Continuing self-heals

Work that is never "done" is a cron worker, not a data migration.

- `WarmCrdtHeads` (hourly, minute 48, `:maintenance`): calls
  `BackfillCrdtHead.enqueue_all/0` (live-vault pairs with a NULL `crdt_head`)
  unless a `BackfillCrdtHead` job is in flight. Every CRDT persist NULLs
  `crdt_head` (`CrdtPersistence.update_v1/4`, plus a trigger on `crdt_state`
  writes, so `CrdtStateSeed` seeding also NULLs it), and only
  `BackfillCrdtHead` re-warms it, so there is never a final "done".
  `BackfillCrdtHead` runs on `:crdt_backfill` (concurrency 1), off
  `:crypto_backfill`, so an hourly re-warm never holds a key rotation's slot.
  A note whose state will not decrypt is logged and skipped; its head stays
  NULL and the batch moves on.

