# Index changes heal themselves: version stamps + the reconcile sweep

_Last verified: 2026-10-04_

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
- A note whose points cannot match on a CURRENT chunker stays unstamped and
  logs a warning each window. Should not happen (the current chunker
  reproduces its own offsets); the warning is the tripwire if it does.
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
