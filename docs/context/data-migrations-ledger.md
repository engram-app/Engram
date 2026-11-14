# Data migrations ledger

_Last verified: 2026-11-07_

## The rule

A data migration that must reach existing rows is an `Engram.DataMigration`
module registered in `Engram.Workers.DataMigrationsRunner` `@migrations`. It is
never an operator command and never a one-off rpc (see "Upgrades require zero
operator action" in `docs/context/migrations-playbook.md`). The runner runs at "boot" (Oban Cron
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
- **Rule (2026-11-06): every NEW data migration defines `enabled?/0` backed
  by a `ServiceConfig` service override** whose key is in `Engram.ServiceConfig.Overrides` (`Engram.ServiceConfig.get(:key,
  true)`, key added to `Engram.ServiceConfig.Overrides`), default on, so a bad
  pass stops fleet-wide in seconds without a deploy (`FileTimes`:
  `file_times_backfill`).
  Ship a test that the switch off runs no pass. Guarded by
  `DataMigrationsRunnerTest` ("newer than the kill-switch rule"), which
  allowlists the migrations that predate the rule.
- **Rule (2026-11-11): a migration may ship OFF** (`ServiceConfig.get(:key,
  false)`), to be switched on by its override after the deploy is validated
  on staging. Name it in `DataMigrationsRunnerTest`'s `@ships_off`; every
  other one must default on (`NoteMeta`).
- A reopen (`DataMigrations.reopen/2`) also restarts that migration's
  id-window walk on every node (`forget/2`), so a walk already past newly
  re-opened work cannot close the ledger clean.
- Optional `reverify?/0` (default `false`). See "Re-verify" below.
- `run_pass/0` returns `:done` only when it found no work. Errors, users
  skipped mid DEK rotation and jobs still in flight are `:more`, or
  `{:more, found}` with a keyword list of what it found (`EnvelopeFormat`
  returns `users: n`), which the runner adds to its log lines.
- `:done` means no row the backfill would process still needs work, checked
  against exactly those rows (the same scan and predicate the worker uses).
- Every statement reads one id window, never "the next N rows that need work"
  (#2276; the backend `AGENTS.md` rule). A pass walks `notes` through
  `Engram.Backfill.IdWindows.heal_pass/4`: each window's step fixes what it
  can and says whether a matched row is still unfixed (a row lock it
  skipped). `:done` is ONE complete walk, start to end, that fixed nothing
  and left nothing; that walk is the completion check, so no separate
  fleet-wide EXISTS runs. A walk can span passes: a pass stops on its time
  budget (240 s) or `:max_fixed`, and the next pass resumes at the cursor,
  so the tail is reached however large the table. A walk that found work
  ends and the next pass starts a new one. Every pass processes at least one
  window. The cursor is node-local (an Agent in the application tree): a
  restart or a pass on another node starts the walk over (slower, never a
  false done). A walk
  spanning more than 3 passes logs a warning per pass and emits
  `[:engram, :id_windows, :walk_spanning]`.
- `NoteIndexState`'s chunk counters are kept on every `chunks` write by the
  `chunks_sync_note_counts_*` statement triggers (migration 20261028000000):
  absolute recount of the touched notes, one state write per note per
  statement. The ledger's windowed recount is the backfill for notes counted
  before the trigger; it is no longer re-verified daily (see "Who
  re-verifies" below).
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
not-done only through a code change (which restarts the node) or
`DataMigrations.reopen/2` (a re-verify that finds work, or the runbook
below), which drops the cache on every connected node (a cache-sync
broadcast).

`IndexVersions` is the exception: its `name/0` embeds the chunker, keyword and
embed model versions, so bumping any of them is a new, not-done migration.

## Drift drain (replaces the daily re-verify)

`EnvelopeFormat`, `LinkResolutionKeys`, `NotePayloadStamps` and `FolderTable`
no longer declare `reverify?/0`: re-walking every row nightly to find drift that is zero
in steady state swapped the 4 GB production database (Job Load Audit
2026-11-03). Drift they guard comes from a previous-release writer, so it is
found continuously instead: `Engram.Workers.BookkeepingDrain` (every 15
minutes, free cron minutes) runs `Engram.Bookkeeping.Drain`, which reads
partial indexes whose predicate IS the drift test (migrations
`20261103130200_index_drift_drain_expand` and
`20261103140100_index_attachments_folder_ref_stale_expand`; the link-key
indexes predate them),
empty in steady state, at most 100 users per index per tick, and hands each
user to the repair that owns it (`ReencodeEnvelopes`, `BackfillLinkKeys`,
`ReconcileNotePayloads`, `FolderTable.run_pass(user_ids: ..)`). Probe
predicates must equal the index text; `test/engram/bookkeeping/drain_test.exs`
pins every probe to its index. `FolderTable`'s attachment drift is found
through a stamp (#2413): every writer sets `attachments.folder_ref_stamp` to
the `path_nonce` the reference was computed from (`Rows.attachment_ref/2`), so
a writer that rewrites the path without re-pointing (the previous release) leaves
`folder_ref_stamp IS DISTINCT FROM path_nonce`, the `attachments_folder_ref_stale`
predicate. Readers trust a reference only while the stamp matches
(`Rows.attachment_ref_current/0`), so there is no watermark any more, and the
walk decrypts only mismatched rows. `Engram.Bookkeeping.Canary` samples the
references readers trust (`folder_ref` invariant) in place of the nightly
check. Markers have no drift source left (this release and the previous one
both create a marker's folder row), so they are only reconciled when a drained
user's pass runs.
A root-level note stores `folder_hmac = HMAC("")` (the column is NOT NULL) and
a NULL `folder_ref_id` forever, so the unresolved-folder predicate excludes
the root by its empty envelope (`octet_length(folder_ciphertext) > 16`).

## Re-verify

A done migration is skipped, so rows that become work again afterwards (an
older node writing the old format during a rolling deploy or after a rollback,
or writes while the migration was disabled) are never picked up until a
version bump. A migration whose `reverify?/0` returns `true` gets its pass
re-run once a day: the runner job scheduled in the 10:00 UTC hour, the one
off-peak window (`DataMigrationsRunner.reverify_hour/0`; `ReconcileEmbeddings`'
10:02 `reverify` run is in the same hour). If that run is
deduped or fails, the day is not lost: any hourly run re-verifies a done row
whose last verification (`completed_at`, rewritten by every `:done`
re-verify) is over 25 h old (`DataMigrations.verified_before?/2`). `:done` calls
`mark_done/2` (idempotent; it re-closes a row another node reopened while this
node still cached `done?`); `:more` calls `DataMigrations.reopen/2` (clears
`completed_at`, restarts the stuck clock, drops the cached `done?` on every node),
and the hourly passes take over until it closes again. The reopen logs at
`:info` ("data migration reopened by re-verify: found users=n"), not
`:warning`: a reopen usually follows an old-release write during a rolling
deploy, and a daily warning would bury a real one. Judge it by the count (a
handful of users is a deploy window; most of the fleet is an old node). The
abnormal cases have their own signals: a raising pass (`:warning`), the stuck
alert, the compression gate gauge and the undecryptable-row `:warning`. Keep
the pass cheap enough to run daily (`FolderTable`'s per-user queries average
~12 ms); a ledger whose drift a partial index can describe is drained instead
(below). `IndexVersions` keeps its own check in `ReconcileEmbeddings`.

### Who re-verifies (2026-11-03)

A re-verify is a full pass, so it costs what the migration's discovery
costs, every day, on a 4 GB RDS whose hot set it evicts. Opt in only when a
real writer can break the invariant after the ledger closes, and prefer a
discovery that reads O(broken rows) over a walk of the table.

| Migration | Re-verified | Why |
|---|---|---|
| `NoteSplit` | no | Invariant kept by the `notes_derive_core_keys` / `notes_sync_body` triggers for every writer of any release. Its daily walk + drift report was ~95 windows/day at ~700 ms and 1.6-1.9k disk reads each, and did not reopen once in 14 days of prod logs (2026-10-19..11-02). |
| `NoteIndexState` | no (v2: one recount on upgrade) | Kept by `notes_sync_index_state` and the `chunks_sync_note_counts_*` triggers, which every writer of any release fires. Its daily walk was ~95 windows/day at ~600 ms and ~1.9k disk reads each; every pass logged since found 0 rows. |
| `EnvelopeFormat` | drain | Reopens in prod (rows written while a rolling deploy held the compression gate shut). No daily re-verify: `Engram.Bookkeeping.Drain` (every 15 min) finds format-0 rows through the `*_envelope_legacy` partial indexes and queues `ReencodeEnvelopes` per user. |
| `LinkResolutionKeys` | drain | Reopens several times a week in prod (an older node re-encrypts without restamping). No daily re-verify: the drain finds stale stamps through the `*_link_keys_stale_index` partial indexes and queues `BackfillLinkKeys`. |
| `NotePayloadStamps` | drain | Reopens in prod (a lost write race NULLs a stamp after the migration closed). No daily re-verify: the drain finds unstamped state rows through `note_index_state_unstamped` and queues `ReconcileNotePayloads`. |
| `FolderTable` | drain (v2: stamps every attachment on upgrade) | Was the last nightly per-user walk (10:00 UTC). No daily re-verify since #2413: the drain finds unresolved notes through `notes_unresolved_folder` and unstamped attachment references through `attachments_folder_ref_stale`, and runs `FolderTable.run_pass/1` for those users. Readers trust an attachment reference only while its stamp matches its `path_nonce`. Kill switch `folder_table_backfill` (service override, default on): off stops only the hourly runner pass; the drain still heals drift through `FolderTable.run_pass(user_ids: ..)`. Maintenance pool has no lock_timeout (runtime_config.ex:292): scope/2's users FOR SHARE can wait up to 120 s instead of 10 s; ends as blocked, not a crash; parked 11-11. |
| `FileTimes` | yes (daily walk) | A 0.75-or-older node that joins after the ledger closed (a rollback to 0.75, or a node that comes and goes between hourly passes) writes floored twins, and no partial index can describe a 1 us drift. The walk reads id, user, doubles and twins by primary key in 200-id windows, a third of the pass budget per table; cost at prod size not measured. A rolling deploy at 10:00 UTC can reopen it with 0 rows (the fleet gate blocks), which the next clean pass closes. |
| `NoteName` | no | Once done, only a rollback below S2 writes paths without names; the stamp mismatch makes S3's readers fall back to the path, and a `version/0` bump walks again. |
| `NoteMeta` | no | Writers derive under the current rules, so nothing new drifts; a rule change bumps `Helpers.meta_version/0`, which renames the migration (a new, not-done walk). A rebound legacy row is handed over by `AadRebind.rebind_note/2` (NULL stamp + reopen). Accepted: a previous-release node in a rolling deploy can write a stamped note under the old rules; it heals on its next edit. |
| `IndexVersions` | on request | While a rollout is open, and on a version-check request (a restored vault: that vault only; an index-version change at boot: the fleet). See `index-version-self-heal.md`. |

A migration that is not re-verified only goes back to work on a
`version/0` bump or `DataMigrations.reopen/2`. `NoteIndexState` is at
version 2 for that reason: its counters were app-kept on 0.66/0.67 and
drifted, so an instance skipping from those releases recounts once.

### Runbook: after a write with triggers disabled

The one gap a trigger cannot close is a write with triggers disabled
(`session_replication_role = replica`, a data-only `pg_restore
--disable-triggers`). After one, reopen the trigger-kept ledgers. `reopen/2`
is cluster-wide: it clears `completed_at` in the table and drops the cached
`done?` on every connected node (cache-sync broadcast), so run it on ANY one
node.

```bash
# Prod (ECS). Staging on FastRaid: docker exec engram /app/bin/engram rpc '...'
aws ecs execute-command --cluster engram-prod --task <any-task-id> \
  --container engram --interactive \
  --command "/app/bin/engram rpc 'Engram.DataMigrations.reopen(\"note_split\", 1); Engram.DataMigrations.reopen(\"note_index_state\", 2)'"
```

Confirm on every node (each entry must be `{:ok, false}`; a missing node
means it is not clustered, so restart it):

```bash
/app/bin/engram rpc 'IO.inspect(for n <- ["note_split", "note_index_state"], v = (if n == "note_split", do: 1, else: 2), do: {n, :erpc.multicall([node() | Node.list()], Engram.DataMigrations, :cached_done?, [n, v])})'
```

and in the table (`completed_at` NULL, `opened_at` now):

```sql
SELECT name, version, completed_at, opened_at FROM data_migrations
WHERE name IN ('note_split', 'note_index_state');
```

The next hourly runner pass (minute 33) walks the table and heals the rows;
`Keys.ids?` falls back to the HMAC columns within a minute and switches back
when `note_split` closes.

## Cross-tenant discovery

Use `DataMigrations.any_row?/1` (a `notes` query) or `IdWindows` directly.
Never `skip_tenant_check: true` on the app pool: FORCE RLS turns that into
zero rows and the migration would close early (#1349). `any_row?/1` walks
`notes` in id windows of 1,000 and asks the query only inside each window,
stopping at the first hit: fleet-wide on the maintenance repo when enabled,
else per user inside that user's RLS context. It is cheapest while work is
left (an early hit) and costs one full walk, one window per statement, to
prove done. The single EXISTS it replaced was slowest exactly when almost
done (#2276).

Per-user windows filter on `user_id`, and `notes` has no `(user_id, id)`
index, so on the per-user path (self-host) a window read is bounded by the
user's row count, not the window. The fleet walk (SaaS) reads the primary key
only.

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
| `EnvelopeFormat` | #1872 PR 3: every compressible DB envelope (`notes.content_ciphertext`, `notes.crdt_state_ciphertext`, `crdt_update_log`, `vault_index_states`, `vault_index_update_log`) off legacy format 0. Each pass enqueues `ReencodeEnvelopes` (`:crypto_backfill`, priority 3) for every user with a legacy row: `octet_length(nonce) = 12 AND octet_length(ct) > 16` (16 = tag only = empty plaintext, legitimately format 0; a 13-byte nonce is done whatever its codec), plus `dek_version >= 2` for the note body (a pre-T3.6 body's empty AAD has no compression policy). No liveness filter: soft-deleted notes and vaults are re-encoded too. The worker decrypts and re-encrypts under the same DEK and AAD, reading only the key, AAD id and the one ciphertext + nonce pair, and writes only ciphertext and nonce, CAS on the old ciphertext, so a concurrent edit wins and `updated_at`/`version`/`seq` never move. The nonce does move, and `CrdtCheckpoint.snapshot_fence/2` and `Notes.rename_fence/1` compare `crdt_state_nonce`: a checkpoint racing a re-encode skips once (re-done next tick), a rename uses its single retry; no data loss. A `crdt_state` rewrite NULLs `crdt_head` via the trigger; when a chain finishes that column it enqueues `BackfillCrdtHead` per vault (`enqueue_user/1`, shared with DEK rotation), not waiting for the hourly `WarmCrdtHeads`. No `RotationLock` (that 503s clients): each batch reloads the user and snoozes while a rotation holds the lock; that gate plus the CAS is the safety, not the queue (Oban OSS limits are per node). A crashed rotation keeps its lock, so after 60 snoozes (~1 h) the job cancels as `:rotation_locked` with a `:warning` naming the user, and the next pass re-enqueues it. A job works ~30 s, then enqueues its successor with its cursor (column + last id) before returning, so the chain is always in flight. One chain per user: `unique` on `user_id` over `available`/`scheduled`/`retryable` (not `executing`, so a job can insert its own successor) drops a duplicate enqueue, discovery skips a user whose job is `executing` (the guard is per user, so one pinned user never stalls the others), and a job that finds a newer in-flight job for its user (a Lifeline-rescued predecessor) cancels itself (`:superseded`). After a Lifeline rescue the hand-off can hit the unique conflict while the rescued predecessor cancels, leaving no chain for that user; the next hourly pass re-enqueues (up to ~1 h delay, no lost work, no false done). Per-user discovery inserts are not atomic and self-heal on the next pass. Each 200-id batch is cut into chunks of at most 8 MB of STORED bytes (`octet_length` probe; always at least one row, so a single huge note still progresses), each committed in its own tenant transaction, so memory and row-lock time are bounded by bytes, not row count. A row that never decrypts is logged (`:warning`, table and row id) and keeps the migration open. `enabled?/0` is `Envelope.compression_on?/0`: false under `ENVELOPE_COMPRESSION=false` or while any cluster node cannot read format 1 (`CompressionGate`); the worker cancels itself on the same decision, checked at job start and before every chunk; `reverify?/0` is true. Attachments and `note_revisions.pending_*` are not re-encoded. |
| `LinkResolutionKeys` | Link resolve-on-read keys (2026-10-18): `path_ci_hmac` + `path_length` on every note/attachment with a `basename_hmac`, `target_key_hmac` on every `note_links` row, each with a `link_keys_stamp` (the source nonce + Unicode version). A key whose stamp does not match the row is ignored by readers and is work here, so a writer that re-encrypts without restamping (the previous release, AAD rebind) cannot leave stale keys trusted. The name embeds the Unicode version: an Elixir upgrade opens a new migration. Each pass enqueues `BackfillLinkKeys` (`:crdt_backfill`, priority 3, one chain per user, 30 s per hop, successors resume at their cursor) for users with an unkeyed row. Writes CAS on the source ciphertext, so a concurrent rename or rotation wins. Snoozes while the user's DEK rotation holds the lock. Reads are exact without the keys (`Engram.Links` decrypts unkeyed rows), so this only makes them cheap. A row that never decrypts stays NULL, is logged, and keeps the migration open. `reverify?/0` is true: an older node in a rolling deploy writes unkeyed rows. |
| `IndexVersions` | Every content-current note stamped with the current chunker, keyword and embed model versions. `ReconcileEmbeddings` does the rebuild. Once done it drops the version term and skips the keyword scan, except on a version-check request (`ReconcileEmbeddings.version_check/1`): a restored soft-deleted vault requests one for that vault's notes, and a boot whose index versions differ from the last boot's (a rollback then roll-forward) requests one for the fleet, chained in 5-minute hops while work remains. See `index-version-self-heal.md`. |
| `NotePayloadStamps` | Qdrant filter HMACs after DEK rotation (2026-10-20). Every filter HMAC derives from the DEK; a rotation rekeys the rows, and its flip transaction NULLs `payload_hash` + `keyword_version` and enqueues `ReconcileNotePayloads` for the user. A rotation before that left the points on the old key, so type/tag/folder/path filters matched nothing. Every indexed note (`kind = 'note'` with a chunk point) gets a `payload_hash`. Each pass enqueues `ReconcileNotePayloads` (`:crdt_backfill`, priority 3, one chain per user, 30 s per hop, 200-note batches with a 200 ms pause) for users with an unstamped note. The worker READS the batch's points (payload keys only), rewrites the drifted ones with `set_payload` (never an upsert, never an embed), clears their `keyword_version` (sparse vectors share the filter key), and stamps with a compare-and-set on the payload columns, so a concurrent index wins and the row stays NULL. A note whose points are all gone is stamped too. v3 points only: a v5-shaped point is read (the scroll matches `user_id` OR a non-empty `u`), skipped and its note left unstamped (#2087 extends the heal); an hour behind a rotation lock logs one warning per job. Re-checks the rotation gate per batch; Qdrant refusal (507/429/503, backpressure) and unapplied waits snooze. Each hop logs its counts and emits `engram_prom_ex_indexing_payload_reconcile_total{outcome}`. Not re-verified: every writer stamps since #2044, and rotation hands its points here. |
| `NoteSizes` | Narrow sizes, liveness and the envelope-drift flag (migration 20261103130000). `note_bodies.content_bytes` / `state_bytes` / `envelope_legacy` are set on the row being written by the BEFORE trigger `note_bodies_sizes` (no extra row; no index on the sizes, so body writes stay HOT). `note_index_state.note_live` rides the existing `note_index_state_sync` upsert. `note_index_state.content_bytes` / `state_bytes` / `has_state` are a narrow copy `CrdtBloatSweep` refreshes hourly for the notes written since its last run (off the save path). Filled here for older rows (one row version each, once; accepted cost: the body fill sets `envelope_legacy` from NULL to false, an indexed column, so that one version per `note_bodies` row is non-HOT and adds primary-key and `note_bodies_user_note` entries, a one-time index rewrite paced by the runner's 240 s budget). Done lets the bloat sweep, snapshot, PostHog sync and budget sweep read narrow columns instead of aggregating every wide `notes` row. Not re-verified. |
| `FileTimes` | R25 migrate-data (`file_times`, v3; v2 re-walked because `FileTime.to_at/1` rounds to the microsecond, where 0.74 and 0.75 floored: desktop Obsidian's sub-millisecond values came out one microsecond low about half the time, as did about a quarter of millisecond values dated 2004-2005 or past 2038-01-19; v3 re-walks because v2 rounded the float product `t * 1e6`, which can land on a false tie (1792348622.2113965 is exactly ...2113964557..., the product ...211396.5, stored ...397), and `to_at/1` now rounds the double's exact binary value with integer math; against the exact rounding, 4 of 12 sampled prod desktop rows were floored low and 1 was v2-high; readers accept a twin within 1 us, `FileTime.twin?/2`, so no payload refresh for those; kill switch `enabled?/0` = service override `file_times_backfill`, default on; a pass walks only while every cluster node reports `FileTime.twin_rounding/0` >= 2 (exact; the v2 build reports 1) via `Readiness.peers_report/4`, the gate `CompressionGate` uses, else it resets the walks and stays open, so the closing walk ran with no 0.75-or-older or v2 node left; read-only check `FileTimes.count_drift/1` per column, expect zeros): the `*_at` timestamptz twins of `notes.mtime`/`ctime`, `attachments.mtime`, `attachment_uploads.mtime` (expand #2445). Work is every row whose twin differs from `FileTime.normalize/1` of its double, NULL or not (a pre-expand release moves the double alone). One `heal_pass/4` walk per table (`file_times:<table>`, 200-id windows, 10,000 rows per walk per pass, a third of the pass budget each); a table that walked clean is skipped on that node while another is open, and when the last open table closes one confirming pass walks all three: done only when that pass finds all three clean. Written only for drifted rows, `FOR NO KEY UPDATE SKIP LOCKED` plus a compare-and-set on the double. Per table per pass: `file times repaired` (`total_count`, the missed-writer guard: silent after the first full walk) and `file_time_out_of_range` (`total_count` of legacy doubles set NULL, written once). A fixed note with a millisecond double gets its `payload_hash` NULLed and `ReconcileNotePayloads` queued for its user (its served `up`/`cr` changed). Accepted risk: a ms note whose twin is already right (written by the expand writer, or healed by `put_at/3` before the walk) is not drift and gets no refresh; its points keep the old `up` until its next index (at most 3 prod notes). Writes only `*_at` and that stamp (no `updated_at`/`seq` move, no fan-out). Readers serve the twin since the read switch (`FileTime.epoch/2`), falling back to the double only while the twin is NULL; `FileTime.put_at/3` heals a stale twin on every write. **No rollback below 0.74.0 once the read switch ships**: a release before 0.74.0 moves the double without its twin, and on roll-forward this release would serve those stale twins. A twin left stale behind the cursor is fixed by the next full walk: the first notes walk spans about 10 hourly passes at prod size (about 94.8k rows at 10,000 per pass), so up to about 10-11 h for notes and about 7 h for attachments; later clean walks fit in one pass. Re-verified daily (`reverify?/0`): a 0.75-or-older node joining after close floors twins again, and the daily walk heals them; contract still bumps `version/0` for one last clean walk before dropping the doubles. |
| `NameTerms` | S1 of the O(1) folder rename plan (`name_terms`, v1): every live note and folder whose `name_terms_stamp` is not `'\x01' \|\| basename_hmac` / `'\x01' \|\| name_hmac` (never written, a previous-release rename or create, a rotated key, a restore) gets its title/filename or folder-name terms rewritten (`Engram.Search.NameTerms`). A pass heals nothing itself: it starts one paced chain (`Engram.Workers.BackfillNameTerms`: 200-id windows over `notes` then `folders`, 250 ms pause per window, 30 s hops that resume at their cursor, at most 500 hops; `Engram.Backfill.Throttle` caps a hop at `name_terms_backfill_max_rows` refs, default 1,000, and `name_terms_backfill_writes_per_s`, default 150, about 24 min at prod size, and holds a hop 60 s when the app pool queue or the oldest open transaction is over `backfill_max_queue_ms` / `backfill_max_xact_s`) when none is in flight and a stale ref exists, and is done when no chain is in flight and the stale partial indexes `notes_name_terms_stale` / `folders_name_terms_stale` are empty (one `LIMIT 1` probe each). The search leg does NOT wait for it. After done, drift is drained (`Engram.Bookkeeping.Drain` `:name_terms`, at most 1,000 refs per user per tick), and the drain also sweeps orphan rows (`:name_terms_orphans`, 500 refs per tick, cycling). A name that never decrypts is stamped `'\x00' \|\| hmac` and leaves the index (logged). Kill switch `enabled?/0` = service override `name_terms_backfill`; the leg's own switch is `name_terms_search`. Not re-verified. |
| `NoteName` | O(1) folder rename plan S2 (Engram#2523): every `notes` (kind note) and `attachments` row, live or not, carries its own name (`Engram.Notes.Name`: `name_ciphertext`/`name_nonce`/`name_hmac`/`name_ci_hmac`, current only while `name_stamp` = `path_nonce` + version byte, `Engram.Crypto.NameKeys`), every `folders` row a `name_ci_hmac` stamped from its `name_nonce`. Writers compute them in one place (`Name.keys/6` via the notes path builder, `Attachments.path_attrs/4`, DEK rotation and AAD rebind; `Folder.name_keys/3` for folders). None of the columns is indexed in S2 (each index ships with the stage that reads it, `folder-rows-writers-and-reads.md`), so the backfill's updates can stay heap-only. The work is NOT a runner pass: each pass only starts `BackfillNoteNames` when none is in flight, one fleet-wide chain (`:crdt_backfill`, cursor in its args, `Engram.Backfill.PacedChain`) of hops of at most `note_name_backfill_max_rows` rows (service override, default 500) or 30 s, at most `note_name_backfill_writes_per_s` rows a second inside a hop (default 150, `Engram.Backfill.Throttle`, whose pressure gate also holds a hop 45 s on a slow app pool or a long open transaction), 250 ms between 100-id windows, 45 s between hops; each window is one probe, one `FOR NO KEY UPDATE SKIP LOCKED` (a held row is left, never waited on) and one CAS UPDATE under `lock_timeout = '2s'`. About 600 rows/min at most, so about 3 h at prod size (estimate, not measured). A row that never decrypts (or has no owner key) is parked: `name_stamp` = `NameKeys.unreadable/1` of its stamp, logged, counted (`[:engram, :note_name, :skipped]`), out of the stale set until a writer rewrites its path. The chain marks the ledger done after a complete clean walk; rows of a user mid rotation are left and stop the chain until the next hourly pass. A walk starts, and the ledger closes, only while every node writes names (`NoteName.fleet_ready?/1`, `Readiness.peers_report/4`). Kill switch `note_name_backfill`, read per window. Not re-verified. |
| `NoteMeta` | #2570 (`note_meta:<Helpers.meta_version>`, v1): every live, AAD-bound kind=note row's stored title, tags and outgoing links re-derived under the current rules (#2564's shared frontmatter fence). `notes.meta_version` (nullable, unindexed) stamps the rule version a note was checked under; NULL = never. `IdWindows.heal_pass/4` over `notes` by primary key (200-id windows, 240 s pass budget, at most 2,000 rewrites a pass); per stale note, in its owner's tenant: row and tail in one statement, `Notes.authoritative_content/3`, then ONE short tenant transaction: a compare-and-set on `version`, `content_hash` and `deleted_at IS NULL` (and no tail row it did not read) writes the stamp, plus title/tags when they moved; `Links.sync_links/4` writes edges only when they differ; a moved title inserts `RebuildStaleNote.enqueue_reread/2` in the same transaction (vectors reused, unmetered). `:done` is one walk that REWROTE nothing: stamps are not fixes, so notes created mid-walk cannot hold it open (writers do not stamp; they derive under the current rules). Legacy (pre-bind) rows are excluded until `AadRebind` binds them. Kill switch `note_meta_backfill`, ships OFF (on after staging validation). Not re-verified. |
| `PersonOriginBackfill` | One-time `country` / `language` / `device_type` PostHog person backfill from Clerk's newest session (`PersonOriginSync.backfill/0`, no operator rpc). The pass reads `oban_jobs` for backfill-chain jobs (args `backfill: true`): any incomplete batch is `:more`; the newest batch completed is `:done` (a chain always holds an incomplete job until its last batch, which inserts its successor first); none, or a discarded/cancelled newest batch, enqueues a fresh chain (head `unique` while incomplete, so the hourly runner and multi-node boot never start two). Completed jobs live 24 h (Oban Pruner); a runner down longer re-runs one idempotent chain. `enabled?/0` is false without PostHog project key and personal API key (self-host, tests). Pacing (~400 ms per user, batches of 100, `:events` queue) lives in the worker. Failed users retry as single jobs, outside the chain. Not re-verified. |

## Pruned (2026-11-07, R8(d))

`NoteBodyColumnsNull` (`note_body_columns_null`, v1, its kill switch and its
per-pass cap `note_body_columns_null_max_fixed`) was deleted, not ported; do
not re-add it. It nulled the `notes.content_ciphertext` /
`crdt_state_ciphertext` copies whose body row already held the same envelope,
only to save space: since R8(c) no reader takes them and since R8(b2) no
writer sets them. R8(e) drops both columns, which frees whatever copies are
left. So an install whose batch never finished (prod was mid-batch on 0.78.1,
about 40k of 67k rows nulled on 2026-11-07) just keeps dead copies until
then. Its ledger row stays; a leftover override row under either key is
ignored with one warning per node (`Engram.ServiceConfig.Overrides`). R8(e)
does not need these columns empty: its guard is that every `kind = 'note'`
row has a `note_bodies` row of the same owner. Recover the code from git
history if a restore ever needs it.

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

