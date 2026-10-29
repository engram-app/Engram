# Context Doc: Backend Architecture

_Moved from AGENTS.md on 2026-10-28._

The component map, key patterns and data flow of the Elixir/Phoenix backend.
For the decision audit (why each choice, what was rejected) see
`docs/context/elixir-architecture-decisions.md`.

## Deployment Modes

| Mode | Real-time | Embedding | Vector DB | PostgreSQL | Attachments |
|------|-----------|-----------|-----------|------------|-------------|
| **SaaS** (primary) | Phoenix Channels (WS) | Voyage AI (`voyage-4-large`, 1024d) | Qdrant Cloud | AWS RDS | AWS S3 |
| **Local dev / CI** | Phoenix Channels (WS) | Ollama (e.g., nomic-embed-text 768d) | Qdrant (Docker) | PostgreSQL (Docker) | Local filesystem |

## Target Components

| Component | Module | Purpose |
|-----------|--------|---------|
| Endpoint | `lib/engram_web/endpoint.ex` | HTTP + WebSocket entry point |
| Router | `lib/engram_web/router.ex` | REST API, MCP, web UI routes |
| Sync Channel | `lib/engram_web/channels/sync_channel.ex` | Per-user bidirectional real-time sync |
| Presence | `lib/engram_web/presence.ex` | Connected device tracking |
| Notes Context | `lib/engram/notes.ex` | Note CRUD, folder ops (Ecto) |
| Indexing | `lib/engram/indexing.ex` | parse → contextualize → embed → upsert pipeline |
| Parser | `lib/engram/parsers/markdown.ex` | Heading-aware chunking (line/regex section splitter) |
| Qdrant Client | `lib/engram/vector/qdrant.ex` | Thin HTTP wrapper (~150 LOC, Req) |
| Embedders | `lib/engram/embedders/` | Voyage AI (SaaS) + Ollama (self-hosted) |
| Search | `lib/engram/search.ex` | Vector search, optional reranking |
| MCP Server | `lib/engram/mcp/` | Hand-rolled MCP server + tool definitions (no external MCP dep) |
| Attachments | `lib/engram/attachments.ex` | AWS S3 (ExAws) or local |
| Auth | `lib/engram/auth.ex` | API keys, internal JWT (Joken), RLS context |
| Clerk Auth | `lib/engram/auth/clerk*.ex` | Clerk JWT verification (SPA + WebSocket primary path) |
| Onboarding | `lib/engram_web/plugs/require_onboarding.ex` | TOS + active-sub gate on vault pipeline (`router.ex:307`) |
| Billing | `lib/engram/billing/`, `lib/engram/paddle/` | Paddle webhook receiver, billing config endpoint, subscriptions |
| Crypto | `lib/engram/crypto/` | Per-user DEKs, AAD bind, master-key rotation, boot canary |
| MCP OAuth | `lib/engram/oauth/`, `lib/engram_web/controllers/oauth_*` | OAuth 2.1 + Dynamic Client Registration for Claude Desktop Connectors |
| Oban Workers | `lib/engram/workers/`, `lib/engram/billing/workers/` | EmbedNote, ReconcileEmbeddings, DataMigrationsRunner, WarmCrdtHeads, DeleteNoteIndex, RotateUserDek, RotateUserMasterKey, AccountExport, InactivityCleanup, MigrateUserProvider, OrphanSweep, AttachmentBlobGC, ReconcileAttachmentBlobs, CleanupVault, VaultDeletedEmail, CleanupDeviceAuthWorker, OriginAbuseSweep, PaddleReconcile, OverrideExpirySweep |

## Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (**no Redis/Valkey anywhere** — BEAM handles PubSub/caches natively; clustered SaaS prod runs a distributed ETS + Phoenix.PubSub rate limiter, self-host plain ETS, and the durable daily search cap is a Postgres token bucket — ElastiCache removed 2026-06-21)
- **PostgreSQL RLS** — DB-enforced tenant isolation via `SET LOCAL app.current_tenant`. `Repo.prepare_query` raises on unscoped queries. See `docs/context/database-schema-rls.md`
- **Three DB roles**: `engram_admin` (migrations, `prepare_database`), `engram_app` (runtime, subject to RLS), `engram_maintenance` (maintenance pool, `maintenance_all` policy). See `docs/context/database-schema-rls.md`
- **Behaviour-based adapters** — `Engram.Embedder` behaviour for Voyage/Ollama
- **Async indexing, sync note storage**: note upsert returns immediately; embedding queued via Oban (30s settle debounce, 5m ceiling, dedup). See `docs/context/async-indexing-pipeline.md`
- **Rust NIFs** (`native/engram_native`, rustler, dirty CPU): the keyword encoder (tokenize + Snowball + HMAC + BM25), 15-43x faster than the Elixir it replaced. **Default to a Rust NIF for CPU-bound pure work** (parsing, tokenizing, hashing, regex, encoding over binaries); keep Elixir for orchestration and I/O. Every NIF follows the memory standard (BEAM allocator, per-call native peak, `[:engram, :nif, :call, :stop]`, unaccounted-RSS poll). Rules, test patterns and the next candidates (markdown chunker, link parser): `docs/context/native-nifs.md`
- **Index changes heal themselves** — a change to chunking or keyword encoding must reach existing notes with NO operator step (self-hosters never run one). Bump `Engram.KeywordIndex` `@version` (keyword-only, free) or `@chunker_version`; `ReconcileEmbeddings` sweeps stale stamps. See `docs/context/index-version-self-heal.md`
- **Per-request query budget + `Engram.Cache`** — every hot path has an exact query count pinned in `test/engram/query_budget_test.exs`; node-local caches are `Engram.Cache` registry entries (trigger NOTIFY eviction), `Repo.with_tenant` is 3 round trips, side effects go in `Repo.after_commit/1`. Adding a cache, reading a budget failure, next targets: `docs/context/request-query-budget.md`
- **Backfills that must reach existing rows** are `Engram.DataMigration` modules on the completion ledger; see `docs/context/data-migrations-ledger.md` (finished one-time backfills are deleted, not ported: see its "Pruned" section)
- **Hybrid chunk storage** — Postgres `chunks` = source of truth for boundaries; Qdrant = vectors + contextualized text
- **Folder-aware context** — folder path + heading hierarchy prepended to chunk text before embedding

## Data Flow

```
Obsidian plugin → WebSocket → Channel "sync:{user_id}" → Presence tracks device

SYNC (immediate): Channel handler → Postgres upsert → PubSub broadcast → other devices
INDEXING (async):  Oban worker → markdown parse → contextualize → Voyage embed → Qdrant upsert
SEARCH:            MCP/REST → Voyage embed query → Qdrant similarity → top N results
```
