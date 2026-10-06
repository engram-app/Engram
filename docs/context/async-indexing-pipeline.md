# Context Doc: Async Indexing Pipeline (Oban)

_Last verified: 2026-10-03 (against `config/config.exs`, `lib/engram/workers/embed_note.ex`, `lib/engram/indexing.ex`)_

## What This Is
All RAG work (parse, embed, Qdrant upsert) runs in Oban jobs. Note writes stay synchronous; the embed is queued after the write commits.

## Why Oban (Not Kafka/RabbitMQ)
Oban uses the existing Postgres. No new infrastructure, no new failure mode. Jobs are rows, so they survive crashes and deploys. Queue list, crontab and shutdown grace live in `config/config.exs` (`config :engram, Oban`); read them there rather than from a copy.

## Flow

```
note write (REST / MCP / CRDT checkpoint)
  -> persist to Postgres, broadcast
  -> EmbedNote.new_debounced(note_id, user_id)   # trailing settle debounce
[worker]
  -> fetch CURRENT note from DB (never from job args)
  -> skip if embed_hash == content_hash AND chunker_version is current
  -> parse -> chunks (lib/engram/parsers/markdown.ex)
  -> context_text = "folder > title > headings\n\ntext"
  -> plan_chunks/4: reuse vectors whose context_text is unchanged (#1592)
  -> embed only the changed chunks (batches of 128) -> Qdrant upsert
  -> stamp embed_hash with an optimistic lock (content changed mid-embed = no-op; next job picks it up)
```

## Debounce and Dedup
- Each edit re-inserts with `replace: [:scheduled_at]`, pushing the run to `now + settle` (default 30s, `EMBED_SETTLE_SECONDS`). A burst of saves collapses to one Voyage call.
- Max-wait ceiling: `scheduled_at` is clamped to `burst_start + max_wait` (default 300s, `EMBED_SETTLE_MAX_WAIT_SECONDS`) so a continuously edited note still embeds. `burst_start` is the surviving job's `inserted_at`.
- Unique per `note_id` across `:incomplete` states, with the period widened to span the whole window.
- Bulk callers using `Oban.insert_all` pass `clamp: false`: `insert_all` ignores `unique`/`replace`, so the ceiling lookup would be wasted.

## Failure and Backpressure
- No custom `backoff/1`: Oban's default exponential backoff, `max_attempts: 5`.
- Voyage 429: the worker returns `{:snooze, n}` (default 60s, `EMBED_429_SNOOZE_SECONDS`), which does not burn an attempt. Optional client-side caps `VOYAGE_RPM` / `VOYAGE_QUERY_RPM` fail fast with a synthetic 429 (`config/runtime.exs`).
- There is no Oban Pro and no Oban rate limiter. Concurrency limits are the backpressure.
- Recovery: the `ReconcileEmbeddings` cron (every 5 min, plus `kick/0` where notes are marked stale) re-enqueues notes on the `idx_notes_embed_pending` partial index (`embed_hash IS NULL OR embed_hash <> content_hash`). That covers exhausted jobs and notes that never got a job.
- Crash safety: `Oban.Plugins.Lifeline` rescues jobs stuck in `executing` (default 60 min). `shutdown_grace_period` (45s) exists so a deploy does not strand an in-flight embed for that hour.

## Re-indexing
A change to the embedding model, context format or chunk boundaries needs a re-embed. There is no automatic corpus-wide reindex:
- Bump `@chunker_version` in `markdown.ex` when chunk boundaries change. `EmbedNote` then refuses to hash-skip notes stamped with an older version, and the `IndexVersions` data migration plus `ReconcileEmbeddings` re-embed them (`docs/context/data-migrations-ledger.md`). The per-vault operator worker `ReindexKeyword` was deleted.

## References
- Oban config: `config/config.exs`
- `lib/engram/workers/embed_note.ex`, `lib/engram/workers/reconcile_embeddings.ex`
- `lib/engram/indexing.ex` (`plan_chunks/4`, `@embed_batch_size`)
- Chunk boundaries and rejected chunking strategies: `docs/context/chunk-boundary-stability.md`
