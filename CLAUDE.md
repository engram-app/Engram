# CLAUDE.md

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on Obsidian. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP. SaaS pricing: Free / Starter $10/mo / Pro $20/mo (v2 reanchored 2026-05-20). Pricing rationale in `../engram-workspace/docs/context/pricing-strategy.md` + `docs/superpowers/specs/2026-05-20-pricing-tiers-v2-design.md`; billing integration details in `docs/context/paddle-integration.md`.

## Issue Tracker

TODOs and open issues live in GitHub Issues for this repo — `gh issue list` to view, `gh issue create` to file. Don't track work in CLAUDE.md, docs/, or ad-hoc TODO.md files.

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
| Auth | `lib/engram/auth.ex` | API keys, internal JWT (Joken), RLS context |
| Clerk Auth | `lib/engram/auth/clerk*.ex` | Clerk JWT verification (SPA + WebSocket primary path) |
| Onboarding | `lib/engram_web/plugs/require_onboarding.ex` | TOS + active-sub gate on vault pipeline (`router.ex:189`) |
| Billing | `lib/engram/billing/`, `lib/engram/paddle/` | Paddle webhook receiver, billing config endpoint, subscriptions |
| Crypto | `lib/engram/crypto/`, `lib/engram/encryption/` | Per-user DEKs, AAD bind, master-key rotation, boot canary |
| MCP OAuth | `lib/engram_web/oauth/` | OAuth 2.1 + Dynamic Client Registration for Claude Desktop Connectors |
| Oban Workers | `lib/engram/workers/` | EmbedNote, ReindexAll, PurgeSoftDeletes, RetryDiscarded, OrphanChunkScan, RotateUserDek, MasterRotation, AadRebind, BackfillContentHashHmac, ReconcileEmbeddings |

### Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (no Redis for PubSub/caches — BEAM clustering handles those natively; SaaS prod uses Redis/ElastiCache **only** as the shared rate-limit store so per-plan/§G and Voyage-quota counters are exact across clustered nodes; self-host stays Redis-free, rate limiter defaults to ETS)
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

All quality lints are fatal in CI: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix sobelow --exit low`, `mix dialyzer`. Configs at `.credo.exs`, `.sobelow-conf`, `.dialyzer_ignore.exs`. Historical phase 1-6 ratchet record + threshold rationale at `docs/context/quality-tooling-baseline.md`.

Deferred ratchets (future): `Readability.Specs` (forces `@spec` on every public function — ~225 outstanding) and `Design.DuplicatedCode` (13 outstanding).

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

## Build Phases — Status

| Phase | What | Status |
|-------|------|--------|
| 1: Scaffold | Phoenix app, Ecto schemas, RLS migrations, auth, health, Oban | shipped |
| 2: Notes CRUD | Upsert/read/delete/rename/changes, path sanitization | shipped |
| 3: Indexing | Earmark parser, Voyage embedder, Qdrant client, pipeline | shipped |
| 4: Search | Vector search, folder/tag filter | shipped |
| 5: Real-time | Phoenix Channel sync, Presence | shipped |
| 6: Attachments | Tigris S3 via ExAws | shipped |
| 7: MCP | Hermes MCP server + OAuth 2.1 + DCR | shipped |
| 8: Web UI | React SPA (Vite + shadcn/ui), Obsidian-style viewer + CodeMirror 6 editor | shipped |
| 9: Deploy | Fly.io for SaaS, OIDC pull-based deploy to self-host, isolated runner VM pool | shipped |
| 10: Billing | Paddle (Merchant-of-Record), subscriptions, RequireOnboarding gate | shipped |
| 11: Encryption | Per-user DEKs + AAD bind + boot canary + per-user DEK rotation | shipped (T3.0-T3.7) |
| Future | AWS KMS provider routing (Tier-4 / Phase F), T3.8-T3.11 hardening, frontend Paddle.js overlay smoke, Rewardful affiliate hookup, annual price IDs | pending |

## Product Tiers

| Tier | Price | Features |
|------|-------|----------|
| **Free** | $0 | 1 vault, 1 device (12h swap cooldown), 1GB attachments, manual sync, 10k notes, 5 AI conversations/day, MCP enabled, 90-day inactivity auto-delete |
| **Starter** | $10/mo ($100/yr) | 5 vaults, unlimited devices, 3GB attachments, real-time SSE sync, 50k notes, 500 AI queries/day, API write access |
| **Pro** | $20/mo ($200/yr) | 15 vaults, unlimited devices, 15GB attachments, real-time sync, unlimited notes, unlimited AI (10k/day fair-use), priority support, higher API rate |

Self-host (no `PADDLE_API_KEY`): free, no billing wiring. See `docs/context/paddle-integration.md` + `../engram-workspace/docs/superpowers/specs/2026-05-20-pricing-tiers-v2-design.md` for the canonical v2 design.

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
| `docs/context/docker-build-cache-pitfalls.md` | Why `_build` cache mount across RUN steps ships stale beams |
| `docs/context/dev-iteration-loop.md` | Local dev loop, hot reload, IEx tricks |
| `docs/context/quality-tooling-baseline.md` | Phase 1-6 lint ratchet history + threshold rationale |
| `docs/context/encryption-operations.md` | Runbooks: master-key rotation, per-user DEK rotation (T3.7), AAD rebind, half-state recovery |
| `docs/context/mcp-oauth.md` | OAuth 2.1 + DCR on `/api/mcp`: wire flow, endpoints, token model, scope grammar, schema |
| `docs/context/paddle-integration.md` | Paddle MoR integration: webhook signature, event lifecycle, `custom_data` contract, affiliate flow |
| `docs/context/billing-tier-frontend-contract.md` | `tier` values (default `free`, not `none`); consumers must handle every tier + gate on `!active` |
| `docs/context/oidc-deploy-cutover.md` | OIDC pull-based deploy daemon, legacy SSH-as-root retirement |
| `docs/context/aws-kms-provider-integration.md` | Tier-4 / Phase F roadmap for KMS provider routing |
| `docs/context/followup-show-attachments-in-tree.md` | One-feature follow-up tracker |
| `docs/context/local-supabase-audit.md` | Throwaway local Supabase stack to run Studio Security/Performance Advisors against the Engram schema (AVX2 CLI build, encrypted-seed, RLS role grant, boot-canary gotchas) |
| `docs/context/spa-state-injection.md` | How Phoenix ships server-known state into `window.__ENGRAM_CONFIG__` so the React SPA can render first-paint-correct UI without a fetch round-trip — the recipe for adding new injected fields, dev vs prod behavior, gotchas (NOT real SSR; see #353) |
| `../engram-workspace/docs/context/pricing-strategy.md` | Cross-workspace SaaS pricing model (lives in workspace repo) |

## Self-host preflight

Operators can preview what the next upgrade will do via:

```bash
mix engram.preflight
```

Inside a running container:

```bash
docker compose exec engram bin/engram eval 'Mix.Tasks.Engram.Preflight.run([])'
```

The output lists pending migrations, their phase tag, whether each is reversible, an estimated lock impact (`:low` / `:medium` / `:high`), and a copy-paste rollback command (only emitted when every pending migration is reversible). When any pending migration is irreversible, the report instructs the operator to take a database backup before pulling the new image.

Implementation: `lib/mix/tasks/engram.preflight.ex`. The `:high` lock-risk flag fires on plain (non-CONCURRENTLY) index creation, drop/rename of a table, column rename, and column type changes — all operations that take ACCESS EXCLUSIVE and block reads/writes for the duration. Raw `execute("...")` SQL is not analyzed; treat as `:high` when uncertain.

## Life OS
project: engram
goal: income
value: financial-freedom
