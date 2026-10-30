# Index changes heal themselves: version stamps + the reconcile sweep

_Last verified: 2026-10-29_

**The standard:** a change to how notes are indexed must reach every EXISTING
note on its own, on SaaS and on every self-host install. A release that needs
"operator: run X per vault after deploy" is a defect. Self-hosters will never
run it, and in SaaS prod the exec path needs the dormant break-glass user.

## The mechanism

Each kind of index change has a version constant in code and a stamp per note.
`Engram.Workers.ReconcileEmbeddings` (cron every 5 min, at boot, and on
`kick/0`; no per-sweep cap) selects notes whose stamp is behind and sends them to the cheapest
worker that brings them current.

| Change | Bump | Stamp | Sweep sends to | Cost |
|---|---|---|---|---|
| Keyword encoding: tokenizer, stemmer, BM25 weighting, WHICH text is encoded | `Engram.KeywordIndex` `@version` | `notes.keyword_version` | `RefreshKeywordVectors` (sparse vectors rewritten in place) | no embedder call |
| Chunk boundaries or chunk text | `Engram.Parsers.Markdown` `@chunker_version` | `notes.chunker_version` | `RebuildStaleNote` (EmbedNote's maintenance path) | re-embed, unmetered |
| Embed model (`DOC_EMBED_MODEL` / `EMBED_MODEL` / the embedder's default) | nothing: config | `notes.embed_model` (dense notes only) | `RebuildStaleNote` | re-embed, unmetered |
| Payload shape only (a key's value or form on the points, vectors unchanged) | `Engram.Indexing.PayloadV6` `@version` | `note_index_state.payload_version` | `ReconcileNotePayloads` (one `set_payloads` batch per page) | zero embedder calls |

**Version rebuilds are unmetered (decided 2026-10-04).** A rebuild of unchanged
content is our maintenance, not the user's usage: it never counts against an
embed cap, even a spent one, and its spend is reported only as
`engram_prom_ex_indexing_maintenance_embed_tokens_total`. A note that HAS
dense vectors keeps them; a sparse-only note stays on the normal budget, so a
bump never grants dense vectors a cap refused. A note needing a full rebuild
skips the keyword sweep (the rebuild stamps both).

NULL means "built before the stamp existed", which is stale. Neither column is
backfilled by its migration: NULL is the evidence of which notes need work.

Every full index (`EmbedNote`) stamps both versions. `RefreshKeywordVectors`
rewrites the keyword vector of every point it can match (dense, sparse or the
legacy unprefixed fingerprint; a row with NO fingerprint, legacy or cleared by
a DEK rotation, by position and offsets) and stamps `keyword_version`. It NEVER
re-embeds: a point it still cannot match is a boundary the current chunker no
longer produces (a v1 chunk whose base64 blob v2 strips), on a note with a
stale `chunker_version`, which the chunker rebuild owns. (An earlier draft re-embedded them; review
found that would have been a near-corpus Voyage bill, and over a spent Free
budget a sparse-only pass that deletes dense points.)

The keyword sweep stamps the same #897 cooldown (`embed_retry_after`) at
selection as the embed sweep, so a note whose resparse keeps failing (a lost
Qdrant point 404s `update_vectors`) is retried once per window, not every tick.

## When you change indexing, ask

1. Do stored vectors for an UNCHANGED note differ after my change? If not, bump
   nothing.
2. Did only the keyword vectors change? Bump `KeywordIndex` `@version`.
3. Did chunk boundaries or chunk text change? Bump `@chunker_version`.
4. Does the sweep route it to a worker that cannot do more than needed? The
   keyword sweep deliberately does NOT go through `EmbedNote`: 96% of prod notes
   also carry a stale `chunker_version` (2026-10-05), and `EmbedNote` answers
   that with a full re-embed.

## Cost of a bump

Every note re-embeds once. The first sweep after the deploy queues all of
them, and the embed queue's concurrency sets the rate. At the 2026-10-04
corpus (4,195 live notes, 96% on an older chunker) that is about 20M Voyage
tokens at most, roughly $2.40. The 0.42.0 rebuild took about two hours under
the old 500-per-15-min cap; uncapped, expect the queue's drain time (a
500-note batch drained in ~2 min). Settle
chunking before it is expensive: bundle boundary changes into one bump.

## Rollout notes

- Cron is leader-elected across every node, web included, and a rolling
  deploy overlaps old and new tasks on one `embed` queue. A job a new node
  enqueues can run on an old node. That is why the sweep's worker is
  `RefreshKeywordVectors`, a name the previous release lacks: its
  `ResparseNote` re-embedded unmatched notes. Version rebuilds go through
  `RebuildStaleNote` for the same reason: the previous release's `EmbedNote`
  rebuilt stale-chunker notes METERED, and a spent Free cap would have dropped
  their dense vectors for good. Apply the rule to any new sweep: if the
  previous release would do something expensive with the job, give the job a
  worker that release does not have.
- The reuse fingerprint and the model stamp name the same model
  (`Indexing.embed_model/0`, which falls back to the embedder's default). A
  fingerprint naming no model would reuse old-model vectors under a new stamp.
- One pass, not two. `RefreshKeywordVectors` rewrites `chunks.token_count`, so
  the vault's avgdl moves during the sweep, and notes refreshed early are
  normalized against an average built mostly from old lengths. For #1615 that
  is a few percent of the BM25 length term: a ranking nudge, not a defect.
  Each later edit re-normalizes its note.
- A note whose points cannot match is stamped anyway and logs ONE info line
  (`resparse left unmatched points`, `stale_chunker: false` on a current
  chunker, shipped to Loki). Should not happen on a current chunker (it
  reproduces its own offsets); that line is the tripwire if it does. The
  unmatched points keep their old keyword vector until an edit re-embeds the
  note. Until 2026-10-30 such a note stayed unstamped and warned every
  backoff window: in prod 671 notes looped twice an hour from the 0.69.0
  deploy (~1,300 oban warnings/hour, firing `engram-prod-loki-oban-discard`),
  each pass rewriting the matched points for nothing.
- It did fire, 2026-10-28 on staging: 1,300 notes, every one a Free note
  embedded with `voyage-4-lite` (35 users), none of the 19,632 large-model
  notes. Cause: resparse runs OUTSIDE an index pass, so it had no pass model
  and built every dense fingerprint as `dense:<embed_model = voyage-4-large>/`.
  A lite point's fingerprint never matched, and because the row HAD a
  fingerprint the offset fallback was skipped. Each note retried every
  cooldown window forever, kept its old keyword dims, and its matched points
  (multi-chunk notes) were rewritten every cycle. Fix: `fingerprint_models/0`
  in `Indexing`, every plan model per plan (`EmbedModels.acceptable(:free)`),
  shared by `resparse_note/2` and `rekey_fingerprints/3`. Not the note's
  `embed_model` stamp: it names the CHEAPEST model the note holds, and a Free
  note keeps large vectors next to new lite ones, so one note's points can
  carry both names. Stuck notes heal on the next sweep, no operator step.
  Rule: any path that computes a dense fingerprint outside `with_pass_model`
  must go through `fingerprint_models/0`.
- `INDEX_REBUILD=dry_run` does not stop the keyword sweep, by design. The
  sweep runs in every mode against `Rebuild.target_versions/0` (the pins,
  `{3, 2}`, off and dry_run), and a NULL `keyword_version` (cleared by payload
  drift healing in `ReconcileNotePayloads`, a DEK rotation, or kept NULL by
  EmbedNote's compare-and-set stamp) is behind any target.
- Watch it: `RefreshKeywordVectors` jobs in the `embed` queue at backfill priority; the
  `reconcile_embeddings: queueing keyword-stale notes` debug line carries
  `eligible_count` / `total_count`.

## A newer stamp is current

`chunker_version` and `keyword_version` are compared with `<`, not `!=`
(`IndexVersions.stale_dynamic/0`, `keyword_stale_dynamic/0`,
`EmbedNote.version_stale?/1`). A release that meets a note stamped by a NEWER
release leaves it alone, so rolling back rebuilds nothing, and the roll
forward finds those notes still current. Before this, a rollback from a
chunker bump re-indexed every note twice. `embed_model` is a string with no
order, so a model rollback still rebuilds.

## A payload-only change has its own stamp

`payload_hash` is the note's OWN computed payload at its last index pass; a new
payload SHAPE never clears it, so before the stamp a new shape reached only
edited notes. `note_index_state.payload_version` (NULL = the baseline, the
shape before the column existed) is the stamp for the shape.
`ReconcileNotePayloads` selects `payload_hash IS NULL OR
COALESCE(payload_version, baseline) < PayloadV6.version()`, merges the new
payload onto the points that do not hold it (`Qdrant.set_payloads/2`, never an
upsert, never `PUT /points/payload`) and stamps the note. It is compared with
`<`: a newer stamp is current, so a rollback rebuilds nothing. It is NOT a
reason to bump `KeywordIndex`/`chunker` versions, and it never calls the
embedder. Rollout order and rollback rule: `docs/context/payload-v6.md`.

## The completion ledger stops the version scans

Once `Engram.DataMigrations.IndexVersions` is done, `ReconcileEmbeddings` drops
the version term and skips the keyword scan. Bumping the chunker, keyword or
model version renames the migration (its name carries all three), which reopens
both scans. No operator step is involved; see
`docs/context/data-migrations-ledger.md`.

**Daily re-verify.** Done does not stay true by itself. Three things put
version-stale notes back after the migration closed, and none renames it:

- a rollback then roll-forward (the old release re-stamps old versions on the
  notes it re-indexes for an edit, then the new name is already done);
- restoring a soft-deleted vault (its notes were excluded while deleted);
- a rolling deploy, where an old-release node stamps an old version after a
  new node marked the new name done.

So `ReconcileEmbeddings` still runs the version term and the keyword sweep
for one hour a day: every tick scheduled 04:00 <= t < 05:00 UTC (twelve
`2-59/5` ticks). A whole hour rather than one tick because the unique window
can dedupe any single tick, and a skipped tick must not skip the day. It is a
pure function of the job's `scheduled_at`, with no extra cron entry and no
state. A stale note is healed within a day; the cost is twelve unindexed
keyword scans per day.

## Keyword v5: phrase pairs dropped (2026-10-27)

v4 added an adjacent-word pair dim per chunk so a quoted query could match
word order inside Qdrant. Measured on prod `engram_notes` (6.89 GB, 408k
points): sparse index + storage was 4.64 GB, and pairs were 50 to 70% of the
sparse entries. The founder decided to drop them; v5 is unigram-only again.

**Quoted phrases now work at query time** (`Engram.Search.PhraseCheck`): when
the query has a double-quoted span, the top 100 fused candidates (constants in
that module) have their chunk text, already loaded and decrypted by the
search path, checked by the Rust tokenizer (`phrase_matches_nif`): the
language-stemmed raw-token stream of the text must hold the phrase's stream
contiguously. Matches are promoted above non-matches (stable, nothing is
filtered, empty or missing text is just unverified). Text is read only up to
64 KB per candidate, so a phrase deep in a floor point stays unverified. The
fetch limit rises to 100 for such queries and the page is cut back to its
usual size after promotion. Telemetry: `engram_prom_ex_search_phrase_checked_total`
and `..._phrase_promoted_total` (no query text). `search_performed` carries
`quoted: true|false` to see how often phrases are used.

**Rollout trap: the in-place rewrite makes disk PEAK before it falls.**
`RefreshKeywordVectors` upserts new (smaller) sparse vectors, but Qdrant only
reclaims the old segment space when the optimizer vacuums, so while the pass
runs, disk and RAM go UP, not down. Watch the Qdrant volume, and let the
vacuum run before judging the saving. Under `INDEX_REBUILD=off|dry_run` the
sweep targets `Rebuild.pinned_versions/0` (keyword 2), so nothing moves until
`on`. No Voyage call is made. The sparse `f16` datatype and the vacuum
threshold are separate changes (staging plus an infra PR).

**The rewrite is paced, so the peak cannot reach strict mode.** Each
`RefreshKeywordVectors` job first passes `Rebuild.qdrant_pace/1`, the same
Qdrant half of the gate the v5 rebuild's `pace/1` uses (minus the Voyage
token bucket, since a resparse costs nothing). It snoozes (never fails)
while any check below fails: 30 s the first time, then doubling with up to
25% jitter to a 600 s ceiling (`Rebuild.gate_snooze/1`, by Oban's
`meta["snoozed"]`). The growth matters: every snooze is a Postgres UPDATE,
and on 2026-10-30 a 10,000-job backlog re-polling a shut gate every 30 s
logged 133,443 snoozes in 15 minutes for ~7,800 rewrites and took prod RDS
CPU from ~8% to ~25% avg for the whole sweep. At the ceiling the same
backlog wakes ~15 times a second instead of ~330. The checks:

- disk is at or over the lower of `:rebuild_max_disk_percent` (default 75)
  and 5 points under the user-write preflight (`Qdrant.preflight_limit/2`,
  the live strict-mode limit less `QDRANT_PREFLIGHT_MARGIN_POINTS`), from the
  cached `Qdrant.pressure/0` volume reading. The live limit is not a fixed 85:
  it is capacity less a reserve that scales with the collection, clamped to
  70..95, so it falls as dead copies grow the collection. Tying the gate to
  it keeps the pass stopping before users' own writes are held back.
  Unknown capacity (self-host has no `/sys_metrics`) never blocks.
- the update queue holds more than 100 operations, or
- the optimizer is behind: collection not green, optimizer not ok, or more
  than `:rebuild_max_queued_points` points awaiting optimization. Waiting on
  the optimizer is what lets the vacuum keep pace with the dead copies.

**The disk gate can stall the pass for good.** The vacuum optimizer only
rewrites a segment once its dead share passes `deleted_threshold`
(`QDRANT_DELETED_THRESHOLD`, default 0.2). The sweep walks notes by id, so
its dead copies spread evenly over every segment: no segment vacuums until
about 20% of the corpus is rewritten, which costs about 20% of the
collection's size in dead copies on top of today's disk. If that sum
reaches the disk gate first, the gate stops the writes that would push a
segment over the threshold, nothing vacuums, disk never falls, and the
sweep snoozes forever (users unaffected). Check before a bump, all in
percent of capacity: `disk% + 100 x 0.2 x disk_bytes / capacity + one
segment's optimization copy` must sit under the gate; if not, lower
`QDRANT_DELETED_THRESHOLD` first. A sustained
`rebuild_gated_total{reason="disk"}` with a flat disk line is the stall.

The full rebuild shares this gate, so it gets the disk check too. A user's
edit (`EmbedNote`) is never gated. Snoozes are counted by reason in
`engram_prom_ex_indexing_rebuild_gated_total{reason}` (`disk`, `queue`,
`optimizer`, `unavailable`, and `tokens` for the rebuild).

The sweep also stops topping up once `:keyword_refresh_backlog` (default
10,000) `RefreshKeywordVectors` jobs are pending. Before that cap, one
reconcile tick queued every keyword-stale note in the fleet at once.
Concurrency is the `embed` queue's limit (5 per worker node), shared with
user edits, which run first (keyword jobs are backfill priority).

**Kill switch: `:keyword_refresh` (no deploy).** `INDEX_REBUILD=off` is NOT
the brake for this sweep. Off drops the keyword target to the pin (2), so
v5-stale notes stop being queued, but jobs already queued (up to the
backlog cap) never read the mode and keep rewriting, and off also halts the
whole v5 pass. Use the runtime override instead, from a release shell on
any one task (ECS Exec, see the workspace `docs/deployment.md`):

```bash
aws ecs execute-command --cluster engram-prod --task <task-id> \
  --container engram --interactive \
  --command "/app/bin/engram rpc 'Engram.ServiceConfig.override(:keyword_refresh, false, by: \"<you>\") |> IO.inspect()'"
# resume: override(:keyword_refresh, true, ...). clear(:keyword_refresh, ...)
# falls back to KEYWORD_REFRESH; prod no longer sets it (engram-infra PR 1688),
# so the default true applies and clear leaves the sweep ON.
```

**Boot default: `KEYWORD_REFRESH` (env).** The override's fallback is the
`KEYWORD_REFRESH` env var (`true` default, so self-host needs nothing). Set
`KEYWORD_REFRESH=false` on BOTH the web and worker task defs (the
reconcile cron and the `embed` queue run on the worker) to boot a release with the sweep
already off, no rpc after the deploy. Then the override is how it goes on:
`override(:keyword_refresh, true, ...)` starts it, `override(..., false, ...)`
or `clear(:keyword_refresh, ...)` stops it again (clear falls back to the env
value, so with `KEYWORD_REFRESH=false` "clear" means OFF, not resume). An
invalid value refuses to boot. Prod does not set it (engram-infra PR 1688
removed it), so there the env default is true and `clear` means ON.

Effect: the write evicts the cached overrides on every node (CacheSync), and
the 15 s cache TTL bounds a lost eviction, so every node reads it within
15 s. From then on each queued `RefreshKeywordVectors` job snoozes 300 s at
perform time before any Qdrant call (a job mid-rewrite finishes its one
note), and the reconcile sweep queues and stamps nothing. Cleared, the
snoozed jobs run on their next wake (within 5 min) and the next tick (within
5 min) tops the backlog up again: no operator backfill. "Back on" means the
resolved value is true: an override of true, or a clear where
`KEYWORD_REFRESH` is unset/true. `EmbedNote` (user
edits) never reads it.

The two knobs are runtime overrides too, same command shape:
`override(:keyword_refresh_backlog, 0..1_000_000)` (0 also stops the sweep
queueing, but leaves queued jobs running) and
`override(:rebuild_max_disk_percent, 1..100)` (also gates the v5 rebuild).
The gate verdict is cached 30 s per node, so a disk-percent change lands
within 15 s + 30 s. `Engram.ServiceConfig.list()` shows what is set. Self-host
leaves all three unset: the defaults (on, 10,000, 75) apply.

## Measuring disk

- **Staging per-point numbers do not predict prod.** Staging (SlowRaid
  Qdrant, collection `obsidian_notes`) carries ~12 KB of payload indexes per
  point vs ~1.9 KB in prod, and ~50 bytes per keyword (sparse) entry vs
  ~26.5 in prod. Measure a disk change on prod's own numbers.
- **`/collections/{c}/memory` overstates real disk.** Its total `disk_bytes`
  sums file sizes (prod: 6.03 GB) while the volume really used 4.9 GB
  (`/sys_metrics` kubelet `volume_stats`). For real disk percent use
  `Engram.Vector.Qdrant.read_pressure().disk`, the same reading the gate
  uses.
- **Prod result of the phrase-pair drop sweep (2026-10-30):** real disk
  53% -> 29% of 16 GiB, keyword data 6.19 -> 2.62 GB, collection file size
  9.78 -> 6.02 GB.
