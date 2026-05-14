# Context Doc: Elixir Architecture Decisions

_Last verified: 2026-04-03_

## Status
Working — these decisions are finalized and guide all implementation.

## What This Is
Complete decision audit for the Engram Elixir/Phoenix architecture. Captures what was chosen, what was rejected, and why.

## Decision Audit (2026-04-02)

| Area | Decision | Rationale |
|------|----------|-----------|
| **Language** | **Elixir/Phoenix** | BEAM VM purpose-built for massive concurrent connections, OTP supervision trees for self-healing, Phoenix Channels for bidirectional real-time sync |
| **Real-time** | **Phoenix Channels (WebSocket)** | Bidirectional, built-in presence tracking, cluster-native PubSub, no reconnect hacks |
| **Multi-tenancy** | **PostgreSQL RLS + tenant_id** | DB-enforced isolation via `SET LOCAL` per transaction, fail-closed (no tenant = no rows), defense-in-depth |
| **DB roles** | **Two roles** | `engram_owner` (migrations, bypasses RLS) + `engram_app` (runtime, subject to RLS) |
| **Clustering** | **dns_cluster** | Auto node discovery via Fly's `.internal` DNS, enables distributed PubSub |
| **PubSub** | **Phoenix.PubSub.PG2** | Native Erlang distribution, cross-region broadcast, no Redis needed |
| **Caching** | **ETS** (Erlang Term Storage) | In-process, clustered via PubSub if needed, eliminates Redis dependency |
| **Rate limiting** | **Hammer** | Token bucket, ETS or Redis backend, Plug integration |
| **Auth: JWT** | **Joken** | Lightweight, Plug-native |
| **Auth: API keys** | **SHA256 hash + ETS cache** | Same security model, fast in-process caching |
| **S3 client** | **ExAws + ExAws.S3** | Battle-tested, Tigris-compatible, official Fly docs |
| **Qdrant client** | **Custom Req HTTP wrapper** (~150 LOC) | No official Elixir SDK; REST API is simple, thin wrapper sufficient |
| **Embeddings** | **Req HTTP wrapper** (~30 LOC) | Same Voyage AI REST API, just different HTTP client |
| **Markdown parsing** | **Earmark AST + custom walker** | Earmark provides full AST, chunking logic reimplemented (~150 LOC) |
| **MCP server** | **Hermes MCP** (Elixir) | Young but functional, working production examples exist |
| **Job queue** | **Oban** (PostgreSQL-backed) | Durable jobs survive crashes/deploys, built-in retry/backoff/dedup/rate-limiting, no new infra (uses existing Postgres) |
| **Testing** | **ExUnit + ExMachina + Mox + Bypass** | `async: true` parallel tests, Ecto.Sandbox per-test transactions |
| **Deployment** | **`fly launch`** (auto-detects Phoenix) | Generates Dockerfile, fly.toml, clustering config automatically |
| **Observability** | **PromEx + Sentry** | PromEx auto-instruments Phoenix/Ecto/Oban/BEAM metrics; Sentry captures errors with stack traces. Both free tier. |
| **Backups** | **Fly volume snapshots** (daily, free) | Sufficient for launch. WAL-based PITR when revenue justifies. Qdrant data is reconstructable from Postgres. |
| **RLS enforcement** | **Layered defense** | Process-dict guard in `Repo.prepare_query` raises on unscoped tenant queries. Safe with PgBouncer transaction mode + Ecto.Sandbox. |
| **IDs** | **BIGSERIAL internal only** | API uses `path` as identifier. Numeric IDs never in responses. Add `public_id UUID` column if share links needed later. |
| **App structure** | **Single OTP app** | No umbrella. Single app is simpler at this scale. Split indexing into separate app only if deployment topology requires it. |
| **Supervision** | **one_for_one** | Independent worker processes. Channel crashes don't affect Oban, Oban crashes don't affect Channels. |
| **Self-hosted embedding** | **Ollama only** | voyage-4-nano requires Voyage API key, contradicts "free, user's own infra." Ollama is truly local. |
| **MCP fallback** | Hermes MCP (primary) | If Hermes abandoned: raw JSON-RPC stdio server (~200 LOC). MCP protocol is simple. Monitor Hermes activity quarterly. |
| **Tokenizer for chunking** | Approximate word-based (~4 chars/token) | Voyage handles actual tokenization. 512 "tokens" is a soft target. |
| **Email** | None for launch | API key auth doesn't need email verification. Add Swoosh for password reset when there are paying users. |
| **Billing** | None for launch (future Phase 10) | Paddle (Merchant-of-Record) integration after core product works — Paddle handles VAT/sales tax globally, simplifying international SaaS pricing. Quota enforcement designed separately. |
| **Load testing** | Deferred to Phase 9 (Deploy) | Key questions: WebSocket connections/machine, embedding throughput, Voyage rate ceiling impact on bulk operations. |

## Unchanged Decisions

| Area | Decision | Details |
|------|----------|---------|
| **Embedding provider** | Voyage AI `voyage-4-large` (1024d, $0.06/M tokens) | Top MTEB, shared space with nano, matryoshka support |
| **Vector DB** | Qdrant Cloud (free tier 1GB) | Same provider, REST API access |
| **Compute** | Fly.io | First-class Phoenix support |
| **Database** | Fly Postgres | With RLS policies |
| **Attachments** | Fly Tigris (S3) | ExAws client |
| **No reranker** | Vector-only search to start | Will benchmark Voyage Rerank 2.5 vs Jina later |
| **Dimensions** | 1024d (Voyage default) | Benchmark 512d later via matryoshka |

## Library Dependencies

| Library | Version | Purpose | Maturity |
|---------|---------|---------|----------|
| **Phoenix** | 1.8+ | Web framework, Channels, PubSub | Production |
| **Ecto** | 3.12+ | Database layer, migrations, schemas | Production |
| **Oban** | 2.18+ | PostgreSQL-backed job queue | Production |
| **Joken** | 2.6+ | JWT sign/verify | Production |
| **ExAws** + **ExAws.S3** | 2.6+ | S3 client for Tigris | Production |
| **Hammer** | 6.1+ | Rate limiting (token bucket) | Production |
| **Redix** | 1.2+ | Redis client (optional) | Production |
| **Earmark** | 1.4+ | Markdown → AST parsing | Production |
| **Req** | 0.5+ | HTTP client (Qdrant, Voyage AI) | Production |
| **Hermes MCP** | latest | MCP server protocol | Early |
| **PromEx** | 1.9+ | Prometheus metrics (Phoenix, Ecto, Oban, BEAM) | Production |
| **Sentry** | 10.0+ | Error tracking | Production |
| **dns_cluster** | 0.1+ | Fly.io node discovery | Production |
| **ExMachina** | dev | Test factories | Production |
| **Mox** | dev | Behaviour-based mocks | Production |
| **Bypass** | dev | HTTP mock server | Production |

## Development Environment

**Local dev on FastRaid (Docker):**
- Elixir app runs in Docker container on FastRaid
- Connects to **real** Voyage AI API (not mocked)
- Connects to **real** Qdrant Cloud (not local)
- Connects to **real** Tigris (not local S3)
- PostgreSQL in Docker (local, with RLS policies)
- This ensures adapters are validated against real services from day 1

**Why Docker on FastRaid:** FastRaid is the dev VM with GPU (for Ollama self-hosted testing). Docker provides consistent Elixir environment without installing Elixir system-wide.

## Infrastructure Setup

| # | Action | Command / Steps | Status |
|---|--------|-----------------|--------|
| 1 | Create Fly app | `fly launch --name engram` (auto-detects Phoenix) | TODO |
| 2 | Create Fly Postgres | `fly postgres create --name engram-db` | TODO |
| 3 | Attach Postgres | `fly postgres attach --app engram engram-db` | TODO |
| 4 | Create Tigris bucket | `fly storage create --name engram-attachments` | TODO |
| 5 | Qdrant Cloud cluster | Create at qdrant.tech (free tier, 1GB RAM) | TODO |
| 6 | Voyage AI API key | Get at voyageai.com | TODO |
| 7 | Set secrets | `fly secrets set VOYAGE_API_KEY=... QDRANT_URL=... QDRANT_API_KEY=... JWT_SECRET=... RELEASE_COOKIE=...` | TODO |
| 8 | Deploy | `fly deploy` | TODO |
| 9 | Verify | `curl https://engram.fly.dev/health/deep` | TODO |

## References
- Build phases: see CLAUDE.md
- Pricing: see `docs/context/pricing-strategy.md`
