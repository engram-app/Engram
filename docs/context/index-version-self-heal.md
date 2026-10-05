# Index changes heal themselves: version stamps + the reconcile sweep

_Last verified: 2026-10-04_

**The standard:** a change to how notes are indexed must reach every EXISTING
note on its own, on SaaS and on every self-host install. A release that needs
"operator: run X per vault after deploy" is a defect. Self-hosters will never
run it, and in SaaS prod the exec path needs the dormant break-glass user.

## The mechanism

Each kind of index change has a version constant in code and a stamp per note.
`Engram.Workers.ReconcileEmbeddings` (cron, every 15 min, 500 notes per sweep
per tick) selects notes whose stamp is behind and sends them to the cheapest
worker that brings them current.

| Change | Bump | Stamp | Sweep sends to | Cost |
|---|---|---|---|---|
| Keyword encoding: tokenizer, stemmer, BM25 weighting, WHICH text is encoded | `Engram.KeywordIndex` `@version` | `notes.keyword_version` | `RefreshKeywordVectors` (sparse vectors rewritten in place) | no embedder call |
| Chunk boundaries or chunk text | `Engram.Parsers.Markdown` `@chunker_version` | `notes.chunker_version` | NOT YET SWEPT (see below) | full re-embed |

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

## Open: the chunker sweep

`chunker_version` is stamped (#1620) but the sweep does not select on it: as of
2026-10-05, turning it on re-embeds ~96% of prod (4,041 of 4,195 notes, ~20M
tokens upper bound), including 2,475 notes of Free users, whose lifetime embed
cap would be charged for our maintenance. Pending decision: version-driven
re-embeds (content unchanged) bypass the user's meter. Until then a chunker
bump still reaches only edited notes, and the keyword sweep's unmatched
points (old chunk boundaries) keep their old keyword vectors.

## Rollout notes

- Cron is leader-elected across every node, web included, and a rolling
  deploy overlaps old and new tasks on one `embed` queue. A job a new node
  enqueues can run on an old node. That is why the sweep's worker is
  `RefreshKeywordVectors`, a name the previous release lacks: its
  `ResparseNote` re-embedded unmatched notes. Apply the same rule to any new
  sweep: if the previous release would do something expensive with the job,
  give the job a worker that release does not have.
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
