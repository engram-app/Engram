# CLAUDE.md

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on Obsidian. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP. SaaS-only at launch: Starter $5/mo, Pro $10/mo. See `docs/context/pricing-strategy.md`.

## Architecture

Engram is a single Elixir/Phoenix OTP application — search, MCP server, note storage, indexing, and real-time sync hub. Notes come in from the Obsidian plugin (or REST API) and are stored in PostgreSQL, parsed, embedded, and indexed into Qdrant. Real-time sync uses Phoenix Channels over WebSocket.

### Deployment Modes

| Mode | Real-time | Embedding | Vector DB | PostgreSQL | Attachments |
|------|-----------|-----------|-----------|------------|-------------|
| **SaaS** (primary) | Phoenix Channels (WS) | Voyage AI (`voyage-4-large`, 1024d) | Qdrant Cloud | Fly Postgres | Fly Tigris (S3) |
| **Local dev / CI** | Phoenix Channels (WS) | Ollama (e.g., nomic-embed-text 768d) | Qdrant (Docker) | PostgreSQL (Docker) | Local filesystem |

### Target Components

| Component | Module | Purpose |
|-----------|--------|---------|
| Endpoint | `lib/engram_web/endpoint.ex` | HTTP + WebSocket entry point |
| Router | `lib/engram_web/router.ex` | REST API, MCP, web UI routes |
| Sync Channel | `lib/engram_web/channels/sync_channel.ex` | Per-user bidirectional real-time sync |
| Presence | `lib/engram_web/presence.ex` | Connected device tracking |
| Notes Context | `lib/engram/notes.ex` | Note CRUD, folder ops (Ecto) |
| Indexing | `lib/engram/indexing.ex` | parse → contextualize → embed → upsert pipeline |
| Parser | `lib/engram/parsers/markdown.ex` | Heading-aware chunking via Earmark AST |
| Qdrant Client | `lib/engram/vector/qdrant.ex` | Thin HTTP wrapper (~150 LOC, Req) |
| Embedders | `lib/engram/embedders/` | Voyage AI (SaaS) + Ollama (self-hosted) |
| Search | `lib/engram/search.ex` | Vector search, optional reranking |
| MCP Server | `lib/engram/mcp/` | MCP tool definitions via Hermes MCP |
| Attachments | `lib/engram/attachments.ex` | Fly Tigris S3 (ExAws) or local |
| Auth | `lib/engram/auth.ex` | API keys, JWT (Joken), RLS context |
| Oban Workers | `lib/engram/workers/` | EmbedNote, ReindexAll, PurgeSoftDeletes, RetryDiscarded, OrphanChunkScan |

### Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (no Redis)
- **PostgreSQL RLS** — DB-enforced tenant isolation via `SET LOCAL app.current_tenant`. `Repo.prepare_query` raises on unscoped queries. See `docs/context/database-schema-rls.md`
- **Two DB roles** — `engram_owner` (migrations) and `engram_app` (runtime, subject to RLS)
- **Behaviour-based adapters** — `Engram.Embedder` behaviour for Voyage/Ollama
- **Async indexing, sync note storage** — note upsert returns immediately; embedding queued via Oban (5s debounce, dedup). See `docs/context/async-indexing-pipeline.md`
- **Hybrid chunk storage** — Postgres `chunks` = source of truth for boundaries; Qdrant = vectors + contextualized text
- **Folder-aware context** — folder path + heading hierarchy prepended to chunk text before embedding

### Data Flow

```
Obsidian plugin → WebSocket → Channel "sync:{user_id}" → Presence tracks device

SYNC (immediate): Channel handler → Postgres upsert → PubSub broadcast → other devices
INDEXING (async):  Oban worker → Earmark parse → contextualize → Voyage embed → Qdrant upsert
SEARCH:            MCP/REST → Voyage embed query → Qdrant similarity → top N results
```

## Local Development

```bash
# Docker Compose (Elixir + PostgreSQL + Qdrant)
docker compose -f docker-compose.elixir.yml up --build

# Outside Docker (requires Elixir 1.17+, PostgreSQL, Qdrant)
mix deps.get
mix ecto.setup          # Create DB + run migrations + seeds
mix phx.server          # http://localhost:4000

# IEx console
iex -S mix phx.server

# Push a test note
curl -X POST http://localhost:4000/notes \
  -H "Authorization: Bearer engram_..." \
  -H "Content-Type: application/json" \
  -d '{"path": "Test/Hello.md", "content": "# Hello\nTest note", "mtime": 1709234567.0}'
```

## Testing

**Tests are the spec. If a test fails, fix the app — not the test.**

| Layer | Command | What |
|-------|---------|------|
| Unit | `mix test` | Pure logic, RLS isolation, auth, HTTP contract (ConnCase) |
| E2E | `python3 -m pytest e2e/tests/ -v` | Real Obsidian sync cycles against Docker stack |

See `docs/context/testing-strategy.md` for full strategy, tooling, and CI pipeline.

## Quality Tooling

Four lints run on every push: `mix format`, `mix compile --warnings-as-errors`, Credo (strict), Sobelow, Dialyzer. Configs at `.credo.exs`, `.sobelow-conf`, `.dialyzer_ignore.exs`. Baseline counts at `docs/context/quality-tooling-baseline.md`.

**Rollout phases** — see `../engram-workspace/docs/superpowers/plans/2026-05-09-quality-tooling-rollout.md`:

| Phase | Tool | Status |
|-------|------|--------|
| 1 | All four installed, informational | shipped |
| 2 | `mix format` + `--warnings-as-errors` fatal | shipped |
| 3 | Sobelow ratchet → zero | shipped |
| 4 | Dialyzer ratchet → zero | shipped |
| 5 | Credo ratchet → zero | shipped |
| 6 | Strict-mode closeout (Sobelow drop `--skip`, document deferred Specs/DuplicatedCode) | shipped |

**Run locally:**

```bash
mix format --check-formatted              # fast, gates immediately
mix compile --warnings-as-errors --force  # fast
mix credo --strict --mute-exit-status     # ~3s, strict mode (default in this repo)
mix sobelow --exit low                    # ~5s (no --skip → annotations surface)
mix dialyzer                              # slow first run (~5-10 min PLT build)
```

**Pre-push hook** (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks`): runs all four informationally in Phase 1. Promoted to fatal phase by phase. Bypass with `git push --no-verify` for WIP / emergency. Dialyzer skipped from pre-push (too slow); CI handles it.

**CI:** `lint` job in `.github/workflows/ci.yml`. PLT cached via `actions/cache@v4` keyed on `mix.lock` hash. Required check on `main` once Phase 2 lands.

**Ratchet semantics** (Phase 3 onward): each phase fixes findings to zero, then promotes the CI step to fatal. Numbers strictly decrease — new PRs that introduce findings fail.

## Build Phases

| Phase | What | Acceptance Criteria |
|-------|------|---------------------|
| **1: Scaffold** | Phoenix app, Ecto schemas, RLS migrations, auth, health, Oban | `GET /health` 200, RLS spike test passes, Oban processes test job |
| **2: Notes CRUD** | Upsert/read/delete/rename/changes, path sanitization | `mix test` CRUD tests pass |
| **3: Indexing** | Earmark parser, Voyage embedder, Qdrant client, pipeline | Upsert triggers embedding + Qdrant upsert |
| **4: Search** | Vector search, folder/tag filter | `mix test` search tests pass |
| **5: Real-time** | Phoenix Channel sync, Presence | E2E sync tests pass |
| **6: Attachments** | Tigris S3 via ExAws | `mix test` attachment tests pass |
| **7: MCP** | Hermes MCP server | MCP tools work from Claude/Cursor |
| **8: Web UI** | LiveView for login, search, logs | Web UI functional |
| **9: Deploy** | Fly.io, dns_cluster, CI, load testing | All tests pass on Fly |
| **10: Billing** *(future)* | Stripe, subscriptions, quotas | Users can subscribe/upgrade |

## Product Tiers

| Tier | Price | Features |
|------|-------|----------|
| **Starter** | $5/mo ($50/yr) | Text search, MCP, WebSocket sync, 5 devices, 10GB storage |
| **Pro** | $10/mo ($100/yr) | + unlimited devices, 50GB, 2x rate limit, multimodal (future) |

14-day free trial (card required). See `docs/context/pricing-strategy.md`.

## Context Docs

| Doc | What |
|-----|------|
| `docs/context/elixir-architecture-decisions.md` | Decision audit, library deps, infra setup checklist |
| `docs/context/async-indexing-pipeline.md` | Oban queues, dedup/debounce, retry, re-indexing |
| `docs/context/channel-event-contract.md` | Phoenix Channel events, conflict flow, plugin integration |
| `docs/context/database-schema-rls.md` | Full SQL schema, RLS policies, Ecto enforcement |
| `docs/context/chunking-retrieval-strategy.md` | Chunking priorities, rejected strategies |
| `docs/context/environment-variables.md` | All env vars by category |
| `docs/context/testing-strategy.md` | Test layers, ExUnit tooling, CI pipeline |
| `docs/context/production-deployment.md` | Fly.io deploy, backups, observability, security checklist |
| `docs/context/pricing-strategy.md` | Full SaaS pricing model |
| `docs/context/docker-build-cache-pitfalls.md` | Why `_build` cache mount across RUN steps ships stale beams |
| `docs/context/benchmark-plan.md` | Embedding/chunking/reranker benchmark methodology |
| `docs/context/code-audit-2026-04.md` | Full codebase audit: 7 CRITICAL, 18 HIGH, 30 MEDIUM findings |
| `docs/context/mcp-oauth.md` | OAuth 2.1 + DCR on `/api/mcp`: wire flow, endpoints, token model, scope grammar, schema |

## Life OS
project: engram
goal: income
value: financial-freedom
