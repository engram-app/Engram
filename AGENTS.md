# AGENTS.md — Engram backend agent & contributor guide

> **Canonical AI/contributor doc.** This is the single source of truth for AI
> coding agents (Claude Code, Copilot, Cursor, Codex, Gemini) and humans working
> on this repo. `CLAUDE.md` is a symlink to this file — edit **this** file only.
> The CI gates enforce correctness; this doc shortens the iteration loop.

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on Obsidian. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP. SaaS pricing: Free / Starter $7/mo / Pro $14/mo (v3 reanchored 2026-05-31). Pricing rationale in `../engram-workspace/docs/context/pricing-strategy.md`; billing integration details in `docs/context/paddle-integration.md`.

## Issue Tracker

TODOs and open issues live in GitHub Issues for this repo — `gh issue list` to view, `gh issue create` to file. Don't track work in this guide, docs/, or ad-hoc TODO.md files.

## Architecture

Engram is a single Elixir/Phoenix OTP application — search, MCP server, note storage, indexing, and real-time sync hub. Notes come in from the Obsidian plugin (or REST API) and are stored in PostgreSQL, parsed, embedded, and indexed into Qdrant. Real-time sync uses Phoenix Channels over WebSocket.

### Deployment Modes

| Mode | Real-time | Embedding | Vector DB | PostgreSQL | Attachments |
|------|-----------|-----------|-----------|------------|-------------|
| **SaaS** (primary) | Phoenix Channels (WS) | Voyage AI (`voyage-4-large`, 1024d) | Qdrant Cloud | AWS RDS | AWS S3 |
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
| MCP Server | `lib/engram/mcp/` | Hand-rolled MCP server + tool definitions (no external MCP dep) |
| Attachments | `lib/engram/attachments.ex` | AWS S3 (ExAws) or local |
| Auth | `lib/engram/auth.ex` | API keys, internal JWT (Joken), RLS context |
| Clerk Auth | `lib/engram/auth/clerk*.ex` | Clerk JWT verification (SPA + WebSocket primary path) |
| Onboarding | `lib/engram_web/plugs/require_onboarding.ex` | TOS + active-sub gate on vault pipeline (`router.ex:307`) |
| Billing | `lib/engram/billing/`, `lib/engram/paddle/` | Paddle webhook receiver, billing config endpoint, subscriptions |
| Crypto | `lib/engram/crypto/`, `lib/engram/encryption/` | Per-user DEKs, AAD bind, master-key rotation, boot canary |
| MCP OAuth | `lib/engram_web/oauth/` | OAuth 2.1 + Dynamic Client Registration for Claude Desktop Connectors |
| Oban Workers | `lib/engram/workers/`, `lib/engram/billing/workers/` | EmbedNote, ReconcileEmbeddings, ReindexKeyword, DeleteNoteIndex, RotateUserDek, RotateUserMasterKey, BackfillContentHashHmac, AccountExport, InactivityCleanup, MigrateUserProvider, OrphanSweep, CleanupVault, VaultDeletedEmail, CleanupDeviceAuthWorker, OriginAbuseSweep, PaddleReconcile, OverrideExpirySweep |

### Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (**no Redis/Valkey anywhere** — BEAM handles PubSub/caches natively; clustered SaaS prod runs a distributed ETS + Phoenix.PubSub rate limiter, self-host plain ETS, and the durable daily search cap is a Postgres token bucket — ElastiCache removed 2026-06-21)
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

**Worktrees**: `git worktree add` fires `.githooks/post-checkout`, which hardlinks `deps/`, `_build/`, and `frontend/node_modules/` from the canonical checkout into the new tree. First-compile time drops from ~3min to ~10sec because mix's incremental compiler skips unchanged files. No setup needed — just `git worktree add <path> -b <branch> origin/main` and start working.

```bash
# Docker Compose (Elixir + PostgreSQL + Qdrant + Ollama; add MinIO via --profile s3)
docker compose up --build

# Outside Docker (requires Elixir 1.15+, PostgreSQL, Qdrant)
mix deps.get
mix ecto.setup          # Create DB + run migrations + seeds
mix phx.server          # http://localhost:4000

# IEx console
iex -S mix phx.server

# Push a test note
curl -X POST http://localhost:4000/api/notes \
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

**CI:** `lint` job in `.github/workflows/verify.yml`. PLT cached via `actions/cache@v4` keyed on `mix.lock` hash. Required check on `main` once Phase 2 lands.

**Ratchet semantics** (Phase 3 onward): each phase fixes findings to zero, then promotes the CI step to fatal. Numbers strictly decrease — new PRs that introduce findings fail.

## Logging conventions

**Principle:** every log line must earn its place by serving *alerting* or *diagnosis*. Healthy systems are quiet — logs are for the exceptional. Routine success (e.g. a per-request 2xx) is not logged to Loki.

**Levels:**

| Level | Means |
|-------|-------|
| `debug` | Developer firehose. Never shipped to Loki. |
| `info` | Normal noteworthy events. |
| `warning` | Off but not broken. |
| `error` | Broken, needs attention. |

**Categories** — nine, the source of truth is `Engram.Logger.Category`: `http`, `sync`, `search`, `auth`, `billing`, `crypto`, `lifecycle`, `oban`, `boot`. Only `billing`, `crypto`, `lifecycle`, `oban`, `boot` ship `info` to Loki; the rest ship only `warning`/`error` (by level).

**How to log (the rule):** always build metadata via `Engram.Logger.Metadata.with_category(level, category, kw)` — it stamps `:category` and the computed `:loki_ship`.

```elixir
Logger.info("subscription created",
  Engram.Logger.Metadata.with_category(:info, :billing,
    paddle_subscription_id: id))
```

NEVER interpolate sensitive values into the message string. `RedactFilter` scrubs sensitive *metadata* keys only — never message strings — so sensitive values must travel as metadata keys (and new metadata keys must be added to the allowlist in `config/config.exs`).

**Sink model:** CloudWatch = full-fidelity archive (Fluent Bit `Match *`, everything). Grafana Loki = curated signal: only lines where `loki_ship` is true (all `warning`/`error`, plus allowlisted `info`). Query Loki day-to-day; CloudWatch is the on-demand backstop.

**Querying Loki:** prod logs are structured JSON (`logger_json` Basic, `metadata: :all`); dev/test stay text. `logger_json` nests metadata under a `metadata` object, so in LogQL after `| json` the fields are `metadata_category`, `metadata_loki_ship`, `metadata_request_id`, etc.

**Depth on demand:** operators can temporarily raise a single module to `:debug` at runtime via release rpc — `Engram.Logger.DebugToggle.enable(SomeModule)` to flip it on while chasing a live issue, `reset(SomeModule)` to flip it back (levels also reset on node restart).

Design spec: `../engram-workspace/docs/superpowers/specs/2026-06-23-logging-taxonomy-redesign-design.md` (engram-workspace repo).

## Build Phases — Status

| Phase | What | Status |
|-------|------|--------|
| 1: Scaffold | Phoenix app, Ecto schemas, RLS migrations, auth, health, Oban | shipped |
| 2: Notes CRUD | Upsert/read/delete/rename/changes, path sanitization | shipped |
| 3: Indexing | Earmark parser, Voyage embedder, Qdrant client, pipeline | shipped |
| 4: Search | Vector search, folder/tag filter | shipped |
| 5: Real-time | Phoenix Channel sync, Presence | shipped |
| 6: Attachments | AWS S3 via ExAws | shipped |
| 7: MCP | Hand-rolled MCP server + OAuth 2.1 + DCR | shipped |
| 8: Web UI | React SPA (Vite + shadcn/ui), Obsidian-style viewer + CodeMirror 6 editor | shipped |
| 9: Deploy | AWS ECS Fargate for SaaS, OIDC pull-based deploy to self-host, isolated runner VM pool | shipped |
| 10: Billing | Paddle (Merchant-of-Record), subscriptions, RequireOnboarding gate | shipped |
| 11: Encryption | Per-user DEKs + AAD bind + boot canary + per-user DEK rotation | shipped (T3.0-T3.7) |
| Future | AWS KMS provider routing (Tier-4 / Phase F), T3.8-T3.11 hardening, frontend Paddle.js overlay smoke, Rewardful affiliate hookup, annual price IDs | pending |

## Product Tiers

| Tier | Price | Features |
|------|-------|----------|
| **Free** | $0 | 1 vault, 1 device (12h swap cooldown), 1GB attachments, manual sync, 10k notes, 5 AI conversations/day, MCP enabled, 90-day inactivity auto-delete |
| **Starter** | $7/mo ($70/yr) | 5 vaults, unlimited devices, 3GB attachments, real-time SSE sync, 50k notes, 500 AI queries/day, API write access |
| **Pro** | $14/mo ($140/yr) | 15 vaults, unlimited devices, 15GB attachments, real-time sync, unlimited notes, unlimited AI (10k/day fair-use), priority support, higher API rate |

Self-host (no `PADDLE_API_KEY`): free, no billing wiring. See `docs/context/paddle-integration.md`.

## Migration phases — the rule

Every PR that adds or modifies a file under `priv/repo/migrations/` MUST carry
exactly one `phase/*` label. CI hard-fails otherwise. Pick by *what the
migration does*, not by what feels safer.

| Label | Use when |
|-------|----------|
| `phase/expand` | Adding a column (nullable, or with default), creating a table, adding a `CREATE INDEX CONCURRENTLY`. Forward-compatible with current main. |
| `phase/migrate-data` | Backfilling a new column, dual-writing while reads switch over. No schema breakage. |
| `phase/contract` | Dropping a column or table that nothing in `lib/` still uses. CI greps to verify. |
| `phase/single-shot` | Combined expand+contract that requires downtime. Allowed only by explicit reviewer waiver — SaaS deploys WILL break during the rollout. |

## Expand/contract — the workflow

When you need to change a column's name, type, or nullability:

1. **Expand PR (release N).** Add the new shape next to the old shape. Code
   writes both, reads the old. Label: `phase/expand`.
2. **Migrate-data PR (release N+1, optional).** Backfill. Flip reads to the
   new shape. Code writes both, reads the new. Label: `phase/migrate-data`.
3. **Contract PR (release N+2).** Remove the code that used the old shape,
   then drop the old shape in the migration. Label: `phase/contract`.

The `contract-phase-references` CI gate enforces step 3: it AST-extracts the
dropped identifiers from your migration and greps `lib/` for them. If any
reference survives, the gate fails. Fix it by going back and shipping the
code removal in an earlier release first.

## Data DML in migrations — FORCE RLS trap

Raw `UPDATE`/`DELETE`/`INSERT` against a tenant table in a migration silently
touches **zero rows on prod**: the migrator (`engram_admin`) owns the tables
but has no BYPASSRLS, migrations set no `app.current_tenant`, and FORCE RLS
binds owners too — dev/CI superusers mask it. Wrap the DML in
`ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` / re-`FORCE` and add a
fail-loud rowcount assertion. `migration_rls_lint_test.exs` enforces this;
full pattern + rationale in `docs/context/migrations-force-rls-data-dml.md`.

## Forbidden in expand-phase migrations

Squawk (run via `priv/repo/lint_migrations.sh`) already hard-fails on:

- `DROP COLUMN`, `DROP TABLE` — use `phase/contract` instead
- `ALTER COLUMN ... TYPE` on a non-trivial change — table rewrite, locks
- `CREATE INDEX` without `CONCURRENTLY` — blocks writes
- Adding a `NOT NULL` column without a `DEFAULT` — table rewrite
- Renaming a column or table — breaks deployed code instantly

Read the Squawk message; it tells you the safe equivalent.

## PG18-era cheap patterns

After the PG16 → PG18 bump (2026-06-10), two patterns that used to require
multi-phase migrations are now safe in a single migrate:

- **`ALTER TABLE ... ADD CONSTRAINT ... NOT NULL NOT VALID`** then
  **`ALTER TABLE ... VALIDATE CONSTRAINT ...`** in a follow-up migrate —
  avoids the full-table scan under `ACCESS EXCLUSIVE`. Use for hardening
  existing columns without blocking writes.
- **`UNIQUE NULLS DISTINCT`** — express "this column is unique except where
  it's NULL" directly, instead of partial-unique-index workarounds.

Phase labels still apply for any column-type change or destructive DDL.

## Baseline / `structure.sql` regen requires a wipe at EVERY env

A baseline regen (rewriting `priv/repo/structure.sql` + `baseline.exs`) only
takes effect on an EMPTY schema — on an existing DB the baseline row in
`schema_migrations` makes it a silent no-op. So such a change MUST be paired
with an actual DB wipe/recreate at every env, and the infra step must be a
**taint + recreate**, never an in-place engine upgrade that preserves data. An
in-place PG16→PG18 bump is exactly what stranded prod on legacy integer PKs on
2026-06-11 (see `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`).
`Engram.Release.verify_schema_baseline/0` now fails the deploy loud if this is
ever missed again.

## The `# safety_assured:` escape

Top-of-file magic comment, justification required:

```elixir
# safety_assured: "rationale — link to PR/issue/incident, what makes this safe here"
defmodule Engram.Repo.Migrations.MyOddOne do
  ...
end
```

When present:

- `mix engram.migration_drops` returns an empty drop list (contract-grep skips the file).
- A reviewer is trusting your justification. Use sparingly; the justification
  must be specific enough that a future reader can audit it.

The existing `# squawk-ignore-file` and `# rollback-irreversible` markers
follow the same pattern — see `priv/repo/lint_migrations.sh` and
`priv/repo/test_rollback.sh` for precedent.

## Migration self-host story

We ship the same migrations to AWS ECS (rolling, zero-downtime) and to
self-hosters (Unraid / engram.ax, container-down → migrate → container-up).
The phase labels exist for SaaS; self-hosters get downtime for free and
don't need to think about phases. The same source-side gates protect them
because the unsafe SQL never enters the migration files they pull.

## Self-host preflight

Operators can preview what the next upgrade will do via:

    mix engram.preflight

Inside a running container:

    docker compose exec engram bin/engram eval 'Mix.Tasks.Engram.Preflight.run([])'

The output lists pending migrations, their phase tag, whether each is
reversible, an estimated lock impact (`:low` / `:medium` / `:high`), and
a copy-paste rollback command (only emitted when every pending migration
is reversible). When any pending migration is irreversible, the report
instructs the operator to take a database backup before pulling the new
image.

Implementation: `lib/mix/tasks/engram.preflight.ex`. The `:high` lock-risk
flag fires on plain (non-CONCURRENTLY) index creation, drop/rename of a
table, column rename, and column type changes — all operations that take
ACCESS EXCLUSIVE and block reads/writes for the duration. Raw `execute("...")`
SQL is not analyzed; treat as `:high` when uncertain.

## Why no Atlas / strong_migrations / custom Credo rules

We evaluated those. Squawk + the two gates added in this file already cover
every destructive change. Adding more tools is Tier 2 work; do not preempt.

## Where migration tooling lives

- Squawk config: `.squawk.toml`
- Lint runner: `priv/repo/lint_migrations.sh`
- New-migration discovery: `priv/repo/list_new_migrations.sh`
- AST extractor: `lib/mix/tasks/engram.migration_drops.ex`
- CI jobs: `.github/workflows/verify.yml` — `phase-label-required`, `contract-phase-references`, `migrations-immutable`, `Lint new migrations (squawk)`, `Test new migrations roll back (ecto.rollback)`

## Context Docs

Grouped index into `docs/context/`. Each entry is a trigger → doc; read the doc itself for full detail.

**Architecture & Decisions**
- Elixir decision audit, library deps, infra checklist (partially superseded — read inline corrections) → `docs/context/elixir-architecture-decisions.md`
- Full SQL schema, RLS policies, Ecto enforcement → `docs/context/database-schema-rls.md`
- All env vars by category → `docs/context/environment-variables.md`
- Rate limiter & cap architecture — Postgres + BEAM only, zero Redis → `docs/context/rate-limiter-architecture.md`
- Cross-workspace SaaS pricing model → `../engram-workspace/docs/context/pricing-strategy.md`

**Sync & CRDT**
- Server-side sync protocol — seq change-log, cursor-pull, manifest, realtime channel (start here for sync work) → `docs/context/sync-protocol.md`
- Phoenix Channel events, conflict flow, plugin integration → `docs/context/channel-event-contract.md`
- CRDT lineage doubling — why the same edit must be encoded exactly once (PR #846) → `docs/context/crdt-lineage-doubling.md`
- CRDT id-keyed rename old-path resurrection race (plugin #183) → `docs/context/crdt-id-keyed-rename-resurrection.md`
- CRDT note_id-collision corruption incident, the id-keying cutover day (2026-07-06) → `docs/context/crdt-id-collision-corruption-2026-07-06.md`
- `Repo.with_tenant/2` funs must return bare values, not `{:ok, _}` → `docs/context/with-tenant-return-wrapping.md`
- `y-indexeddb` `whenSynced` never resolves after `destroy()` → `docs/context/y-indexeddb-whensynced-destroy-hang.md`

**Indexing & Search**
- Oban indexing pipeline — dedup/debounce, retry, re-indexing → `docs/context/async-indexing-pipeline.md`
- Chunking priorities, rejected strategies → `docs/context/chunking-retrieval-strategy.md`
- Lingua NIF memory — `low_accuracy_mode` dial, the #891 OOM crash-loop → `docs/context/lingua-language-detection-memory.md`

**Billing & Pricing**
- Paddle MoR integration — webhook signature, event lifecycle, `custom_data`, affiliate flow → `docs/context/paddle-integration.md`
- Paddle list pagination — stop on `has_more`, never `next` (PR #723 infinite-loop fix) → `docs/context/paddle-list-pagination-has-more.md`
- `tier` values contract (default `free`, gate on `!active`) → `docs/context/billing-tier-frontend-contract.md`
- Attachment MIME/extension whitelist abuse defense (Pricing v2 §H) → `docs/context/attachment-mime-whitelist.md`

**Auth, OAuth & MCP**
- OAuth 2.1 + DCR on `/api/mcp` — wire flow, endpoints, token model, scopes → `docs/context/mcp-oauth.md`
- MCP vault selection design — stateless `set_vault`, fate of the default vault → `docs/context/mcp-vault-selection.md`
- Refresh-token rotation — leeway/overlap window, token-family reuse detection → `docs/context/refresh-token-reuse-detection.md`
- How `/settings/connections` identifies an OAuth/MCP client → `docs/context/connections-client-identity.md`
- Onboarding demo vault poisons `activeVaultId` → prod 404 storm (fixed) → `docs/context/demo-vault-activevaultid-poisoning.md`

**Frontend / SPA**
- Frontend SPA map — bootstrap chain, runtime router, api/sync/realtime layer, viewer/editor (start here for web-app work) → `docs/context/frontend-architecture.md`
- `window.__ENGRAM_CONFIG__` first-paint state injection pattern → `docs/context/spa-state-injection.md`
- Login critical-path optimization (PR #673) — rolldown-vite `manualChunks` gotcha → `docs/context/frontend-login-load-optimization.md`
- Login boot perf (PR #842) — chunk-size measurement, VLQ-decode under hidden sourcemaps → `docs/context/frontend-login-boot-perf.md`
- Folder-tree `rebuildTree()` triggers, optimistic move/delete/duplicate → `docs/context/folder-tree-optimistic-rebuild.md`
- Frontend/backend deploy-trigger skew (different pipelines) — 2026-06-20 incident + fix → `docs/context/frontend-backend-deploy-skew-cors.md`

**Testing & CI**
- Full test strategy, ExUnit tooling, CI pipeline → `docs/context/testing-strategy.md`
- CI pipeline & gating — what runs vs what gates, post testing-architecture migration → `docs/context/ci-pipeline-gating.md`
- Running the ExUnit suite locally against Docker Postgres → `docs/context/local-backend-testing.md`
- Running OAuth/Clerk e2e tests locally (test_47/test_48) → `docs/context/local-oauth-e2e-testing.md`
- `Vault not registered after 15s` E2E diagnostic ladder — don't just bump the timeout → `docs/context/e2e-vault-registration-diagnostics.md`
- `Application.put_env` in `async: true` tests is a flake source → `docs/context/exunit-application-env-races.md`
- Why `prebuild-mix` recompiled everything despite cache hits (absolute-path compile manifest) → `docs/context/ci-mix-compile-cache-runner-path.md`
- Bun lifecycle-script trust model, `trustedDependencies`, the pngquant CI flake (#975) → `docs/context/bun-postinstall-trust.md`

**Deploy & Infra**
- AWS ECS deploy, backups, observability, security checklist → `docs/context/deploy-prod.md`
- Launch-minimum DR runbook — RDS snapshots, S3 versioning, Qdrant reindex fallback → `docs/context/disaster-recovery.md`
- Why `_build` cache mount across Docker RUN steps ships stale beams → `docs/context/docker-build-cache-pitfalls.md`
- Local dev loop, hot reload, IEx tricks → `docs/context/dev-iteration-loop.md`
- Preview frontend changes against a locally-running real backend → `docs/context/local-dev-preview-stack.md`
- Throwaway local Supabase stack to run Studio Security/Performance Advisors against the schema → `docs/context/local-supabase-audit.md`
- PG18/UUIDv7 prod crash-loop root cause — in-place engine bump vs specced taint+recreate; `verify_schema_baseline/0` guard → `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`
- `mjml` vs `lingua` rustler_precompiled version conflict — pin override → `docs/context/rustler-precompiled-nif-conflict.md`
- Worktree hardlinked `deps/`/`_build/` can omit yecc/leex-generated beams (pre-push failures) → `docs/context/worktree-deps-artifact-staleness.md`
- Tier-4 / Phase F roadmap for AWS KMS provider routing → `docs/context/aws-kms-provider-integration.md`

**Encryption**
- Runbooks: master-key rotation, per-user DEK rotation (T3.7), AAD rebind, half-state recovery → `docs/context/encryption-operations.md`
- Invalid UTF-8 at rest (bytea bypasses PG validation) → `Jason.encode` 500 at every JSON egress; fix + backfill task → `docs/context/invalid-utf8-at-rest-json-500.md`

**Perf & Quality**
- Read-path decrypt perf — parallel_map economics, when it helps vs hurts → `docs/context/read-path-decrypt-perf.md`
- Perf caches + invalidation contracts (2026-06-12 audit wave) → `docs/context/perf-caching-invalidation.md`
- Phase 1-6 lint ratchet history + threshold rationale → `docs/context/quality-tooling-baseline.md`
- OpenAPI spec pipeline — schema modules, drift-gate CI, HostRewrite/version-recompile gotchas → `docs/context/openapi-docs-pipeline.md`

## Superpowers spec docs → Engram vault (overrides the skill default)

When `superpowers:brainstorming` produces a design/spec doc, save it to the **Engram vault** at `50 Engineering/_Superpowers Specs/YYYY-MM-DD-<topic>-design.md` via the engram MCP (`set_vault` → Engram `4c2057f9-a6cb-4e5e-9b4e-7ac50fb77c35`, `create_note`/`write_note`, then `set_vault()` to reset) — **not** to `docs/superpowers/specs/`. Specs are durable design rationale, so they live in the vault (searchable, dogfoods engram). This user instruction takes precedence over the skill's local-save step.

**Plans stay repo-local.** `superpowers:writing-plans` output is an ephemeral implementation checklist — keep it in `docs/superpowers/plans/` as the skill specifies; do not route plans to the vault.

## Life OS
project: engram
goal: income
value: financial-freedom
worklog_vault: Engram
worklog_path: 90 Work Log/todd
