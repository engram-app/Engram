# Context Doc: Async Indexing Pipeline (Oban)

_Last verified: 2026-06-18 (against `config/config.exs` + `lib/engram/workers/`)_

## Status
Live. Core EmbedNote mechanics (debounce, dedup, content-hash skip, DB-is-source-of-truth) are current. Queue list + crontab below regenerated from `config/config.exs:55-74`.

## What This Is
Complete specification for the Oban-based async embedding pipeline. All RAG work (parse → embed → Qdrant upsert) runs asynchronously. Note sync remains synchronous and immediate.

## Why Oban (Not Kafka/RabbitMQ)
Oban uses the existing PostgreSQL database — no new infrastructure, no new failure mode, no additional cost. Engram is a single OTP app where the web endpoint hands off work to a background processor. Jobs are Postgres rows — they survive app crashes, deploys, and restarts.

## Request Flow

```
POST /notes (or Channel push_note)
  → Persist to PostgreSQL (immediate, in request)
  → Compute content_hash — if unchanged from previous, skip Oban job
  → Increment version
  → Broadcast via PubSub to all connected devices (immediate)
  → Oban.insert(EmbedNoteWorker, %{note_id: id}, unique/replace opts)
  → Return 200 with note metadata + "indexing": "queued"

[Oban worker picks up job — 5s debounce]
  → Fetch CURRENT note content from DB (not from job args — always latest)
  → Parse markdown → chunks (Earmark AST)
  → Contextualize (prepend folder > title > heading)
  → Batch embed via Voyage AI (all chunks in one API call, up to 128 texts)
  → Delete old chunks (Postgres + Qdrant) for this note
  → Insert new chunks (Postgres metadata + Qdrant vectors)
  → On failure: retry with backoff (see schedule below)
```

## Oban Queues

From `config/config.exs:58` — `queues: [embed: 5, reindex: 1, maintenance: 2, crypto_backfill: 1, export: 1]`. There is no Oban Pro and no `rate_limit` queue option (`engine: Oban.Engines.Basic`, plugins are only Pruner/Lifeline/Cron). Voyage backpressure is enforced by the worker snoozing on 429s, not by an Oban rate limiter (see Backpressure below).

| Queue | Concurrency | Purpose |
|-------|------------|---------|
| `embed` | 5 | Per-note embedding after upsert (`EmbedNote`) |
| `reindex` | 1 | Bulk re-embedding — model/context migration (`reindex_keyword.ex`, reindex workers) |
| `maintenance` | 2 | General background maintenance |
| `crypto_backfill` | 1 | DEK/master-key rotation + content-hash HMAC backfill (`rotate_user_dek.ex`, `rotate_user_master_key.ex`, `backfill_content_hash_hmac.ex`, `migrate_user_provider.ex`) |
| `export` | 1 | Account data export (`account_export.ex`) |

## Deduplication & Debouncing

**Problem:** A user edits a note 10 times in 30 seconds. Without dedup, 10 embedding jobs run (10x API cost, 10x Qdrant writes).

**Solution:** Oban's `unique` + `replace` options:

```elixir
defmodule Engram.Workers.EmbedNote do
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,                          # dedup window
      keys: [:note_id],                    # one job per note
      states: :incomplete                  # dedup across all not-yet-completed states
    ]

  @impl true
  def perform(%Job{args: %{"note_id" => note_id}}) do
    # Always fetch CURRENT content from DB — not from job args.
    note = Repo.get!(Note, note_id)
    # ... parse, embed, upsert
  end
end

# Called from NoteController / Channel handler:
Oban.insert(EmbedNote.new(
  %{note_id: note.id},
  scheduled_at: DateTime.add(DateTime.utc_now(), 5, :second),  # 5s debounce
  replace: [:scheduled_at]  # reset debounce timer on re-insert
))
```

**How 10 rapid edits collapse to 1 job:**
1. Edit 1 → INSERT job (note_id=42, scheduled_at=now+5s)
2. Edit 2 → REPLACE job (note_id=42, scheduled_at=now+5s) — timer reset
3. ...edits 3-10 → each REPLACE resets the timer
4. 5 seconds after the LAST edit → ONE job runs, fetches latest content from DB
5. **Result:** 1 Voyage API call instead of 10. 90% cost savings.

**Content hash skip:** Before inserting the Oban job, compute `SHA256(content)` and compare to `notes.content_hash`. If identical (e.g., metadata-only change from a rename), no embedding job is created at all.

## Retry & Failure Strategy

| Attempt | Backoff | What happens |
|---------|---------|-------------|
| 1 | Immediate (after 5s debounce) | Normal execution |
| 2 | 30 seconds | Voyage API might be rate-limited |
| 3 | 2 minutes | Transient outage |
| 4 | 15 minutes | Extended outage |
| 5 | 1 hour | Last attempt |
| Exhausted | Move to `discarded` | Note is stored but not searchable |

**Embed-backlog recovery:** The `ReconcileEmbeddings` cron (every 15 min) re-enqueues notes whose embedding is missing/stale — it scans the `idx_notes_embed_pending` partial index (`embed_hash IS NULL OR embed_hash <> content_hash`) rather than scanning Oban's `discarded` table. This covers both exhausted jobs and notes that never got a job.

**Crash safety:** Oban's `Lifeline` plugin (config.exs:61) detects jobs stuck in `executing` after a node crash and moves them back to `available` for retry.

## Backpressure

- **Oban concurrency limit** — `embed` queue runs max 5 concurrent workers. If 500 notes are pushed at once, they queue and process 5 at a time.
- **Voyage AI rate limiting** — handled in the worker, NOT by an Oban rate limiter. On a Voyage `429` the worker returns `{:snooze, n}` (default 60s, env `EMBED_429_SNOOZE_SECONDS`) which reschedules without burning an attempt (`embed_note.ex:179-210`). Optionally, a client-side cap (`VOYAGE_RPM` / `VOYAGE_QUERY_RPM`) fails fast with a synthetic 429 before the real API call (`runtime.exs:131-137`).
- **Qdrant writes** — each embed job does one batch upsert per note (not per chunk), so write pressure scales with notes, not chunks.
- **Memory** — workers fetch one note at a time from DB; no risk of loading 500 notes into memory simultaneously.

## Scheduled Jobs (Cron)

Verbatim from `config/config.exs:55-74`:

```elixir
config :engram, Oban,
  engine: Oban.Engines.Basic,
  repo: Engram.Repo,
  queues: [embed: 5, reindex: 1, maintenance: 2, crypto_backfill: 1, export: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},   # prune completed jobs after 7 days
    Oban.Plugins.Lifeline,                            # rescue orphaned (post-crash) jobs
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Engram.Workers.ReconcileEmbeddings},     # re-enqueue missing/stale embeds
       {"0 * * * *",    Engram.Workers.CleanupDeviceAuthWorker}, # hourly: expire device-auth codes
       {"0 2 * * *",    Engram.Billing.Workers.PaddleReconcile}, # daily: reconcile subscription state
       {"0 3 * * *",    Engram.Billing.Workers.OverrideExpirySweep}, # daily: expire limit overrides
       {"30 3 * * *",   Engram.Workers.InactivityCleanup},       # daily: inactivity warnings + cleanup
       {"0 4 * * *",    Engram.Workers.OriginAbuseSweep},        # daily: client-origin abuse sweep
       {"0 5 * * 0",    Engram.Workers.OrphanSweep}              # weekly Sun: cross-store orphan cleanup (Qdrant/S3)
     ]}
  ]
```

> `PurgeSoftDeletes` / `RetryDiscarded` / `OrphanChunkScan` do **not** exist. Soft-delete + cross-store orphan cleanup is `OrphanSweep` (weekly); embed re-enqueue is `ReconcileEmbeddings` (every 15 min); test env disables Oban entirely (`config/test.exs:79`, `testing: :manual`).

## Re-indexing & Embedding Migration

Re-indexing is needed when **any** of these change: embedding model, context format, chunk size, or structure preservation rules.

**Triggers requiring full re-index:**
- Model change (e.g., Voyage 4 → Voyage 5) — different vector space
- Context format change (e.g., adding folder-aware prepending) — same model, different input text
- Chunk size change (e.g., 512 → 1024 tokens) — different chunk boundaries
- Multimodal upgrade (voyage-multimodal-3.5) — different vector space

**Blue-green strategy:** (the live collection is `engram_notes` — see `docs/context/environment-variables.md` for the `QDRANT_COLLECTION` default nuance)
1. Create second Qdrant collection (e.g. `engram_notes_v2`)
2. Oban `reindex` queue processes all notes (low priority, max concurrency 1)
3. Each note: re-parse → re-contextualize → re-embed → upsert to v2 collection + update Postgres `chunks`
4. When complete: swap `QDRANT_COLLECTION` pointer to v2, delete v1
5. Zero downtime — search uses whichever collection the pointer references

**Cost:** ~$225 at 5K users for full re-embed (Voyage API). Trivial.

**Implementation:** `Engram.Workers.ReindexAll` Oban worker on the `reindex` queue — a first-class background job with progress tracking, resumability, and failure handling.

**Metadata:** Store `{model, context_format_version, chunk_config}` with each Qdrant collection for tracking.

## References
- Oban config (queues + crontab): `config/config.exs:55-74`
- EmbedNote worker: `lib/engram/workers/embed_note.ex`
- Oban workers (full set): `lib/engram/workers/`, `lib/engram/billing/workers/`
- Indexing orchestrator: `lib/engram/indexing.ex`
- Chunking strategy: `docs/context/chunking-retrieval-strategy.md`
