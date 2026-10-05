# Index changes heal themselves: version stamps + the reconcile sweep

_Last verified: 2026-10-05_

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
| Keyword encoding: tokenizer, stemmer, BM25 weighting, WHICH text is encoded | `Engram.KeywordIndex` `@version` | `notes.keyword_version` | `ResparseNote` (sparse vectors rewritten in place) | no embedder call |
| Chunk boundaries or chunk text | `Engram.Parsers.Markdown` `@chunker_version` | `notes.chunker_version` | NOT YET SWEPT (see below) | full re-embed |

NULL means "built before the stamp existed", which is stale. Neither column is
backfilled by its migration: NULL is the evidence of which notes need work.

Every full index (`EmbedNote`) stamps both versions. `ResparseNote` rewrites
the keyword vector of every point it can match (dense, sparse or the legacy
unprefixed fingerprint) and stamps `keyword_version`. It NEVER re-embeds: a
point it cannot match is a legacy row with no fingerprint or a v1 chunk whose
base64 blob v2 strips, and both sit on notes with a stale `chunker_version`,
which the chunker rebuild owns. (An earlier draft re-embedded them; review
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
points (legacy rows) keep their old keyword vectors.

## Rollout notes

- The sweep runs wherever Oban's cron runs (the worker tier in prod). Notes
  stamped by an old worker mid-deploy are simply re-selected once the new
  worker's sweep runs.
- Watch it: `ResparseNote` jobs in the `embed` queue at backfill priority; the
  `reconcile_embeddings: queueing keyword-stale notes` debug line carries
  `eligible_count` / `total_count`.
