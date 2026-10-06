# AGENTS.md — Engram backend agent & contributor guide

> **Canonical AI/contributor doc.** This is the single source of truth for AI
> coding agents (Claude Code, Copilot, Cursor, Codex, Gemini) and humans working
> on this repo. `CLAUDE.md` is a symlink to this file — edit **this** file only.
> The CI gates enforce correctness; this doc shortens the iteration loop.

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on Obsidian. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP. SaaS pricing: Free / Starter $7/mo / Pro $14/mo (v3 reanchored 2026-05-31). Pricing rationale in `../engram-workspace/docs/context/pricing-tiers-v2-decisions.md` (the old `pricing-strategy.md` pointer named a file that does not exist); billing integration details in `docs/context/paddle-integration.md`.

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
| Crypto | `lib/engram/crypto/`, `lib/engram/encryption/` | Per-user DEKs, AAD bind, master-key rotation, boot canary |
| MCP OAuth | `lib/engram_web/oauth/` | OAuth 2.1 + Dynamic Client Registration for Claude Desktop Connectors |
| Oban Workers | `lib/engram/workers/`, `lib/engram/billing/workers/` | EmbedNote, ReconcileEmbeddings, DataMigrationsRunner, WarmCrdtHeads, DeleteNoteIndex, RotateUserDek, RotateUserMasterKey, AccountExport, InactivityCleanup, MigrateUserProvider, OrphanSweep, CleanupVault, VaultDeletedEmail, CleanupDeviceAuthWorker, OriginAbuseSweep, PaddleReconcile, OverrideExpirySweep |

### Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (**no Redis/Valkey anywhere** — BEAM handles PubSub/caches natively; clustered SaaS prod runs a distributed ETS + Phoenix.PubSub rate limiter, self-host plain ETS, and the durable daily search cap is a Postgres token bucket — ElastiCache removed 2026-06-21)
- **PostgreSQL RLS** — DB-enforced tenant isolation via `SET LOCAL app.current_tenant`. `Repo.prepare_query` raises on unscoped queries. See `docs/context/database-schema-rls.md`
- **Two DB roles** — `engram_owner` (migrations) and `engram_app` (runtime, subject to RLS)
- **Behaviour-based adapters** — `Engram.Embedder` behaviour for Voyage/Ollama
- **Async indexing, sync note storage**: note upsert returns immediately; embedding queued via Oban (30s settle debounce, 5m ceiling, dedup). See `docs/context/async-indexing-pipeline.md`
- **Rust NIFs** (`native/engram_native`, rustler, dirty CPU): the keyword encoder (tokenize + Snowball + HMAC + BM25), 15-43x faster than the Elixir it replaced. **Default to a Rust NIF for CPU-bound pure work** (parsing, tokenizing, hashing, regex, encoding over binaries); keep Elixir for orchestration and I/O. Every NIF follows the memory standard (BEAM allocator, per-call native peak, `[:engram, :nif, :call, :stop]`, unaccounted-RSS poll). Rules, test patterns and the next candidates (markdown chunker, link parser): `docs/context/native-nifs.md`
- **Index changes heal themselves** — a change to chunking or keyword encoding must reach existing notes with NO operator step (self-hosters never run one). Bump `Engram.KeywordIndex` `@version` (keyword-only, free) or `@chunker_version`; `ReconcileEmbeddings` sweeps stale stamps. See `docs/context/index-version-self-heal.md`
- **Backfills that must reach existing rows** are `Engram.DataMigration` modules on the completion ledger; see `docs/context/data-migrations-ledger.md` (finished one-time backfills are deleted, not ported: see its "Pruned" section)
- **Hybrid chunk storage** — Postgres `chunks` = source of truth for boundaries; Qdrant = vectors + contextualized text
- **Folder-aware context** — folder path + heading hierarchy prepended to chunk text before embedding

### Data Flow

```
Obsidian plugin → WebSocket → Channel "sync:{user_id}" → Presence tracks device

SYNC (immediate): Channel handler → Postgres upsert → PubSub broadcast → other devices
INDEXING (async):  Oban worker → markdown parse → contextualize → Voyage embed → Qdrant upsert
SEARCH:            MCP/REST → Voyage embed query → Qdrant similarity → top N results
```

## Local Development

**Worktrees**: `git worktree add` fires `.githooks/post-checkout`, which hardlinks `deps/`, `_build/`, and `frontend/node_modules/` from the canonical checkout into the new tree. First-compile time drops from ~3min to ~10sec because mix's incremental compiler skips unchanged files. No setup needed — just `git worktree add <path> -b <branch> origin/main` and start working.

```bash
# Docker Compose (Elixir + PostgreSQL + Qdrant + Ollama; add MinIO via --profile s3)
docker compose up --build

# Outside Docker (requires Elixir 1.15+, PostgreSQL, Qdrant, Rust via rustup:
# `mix compile` builds native/engram_native; rustup picks the pinned toolchain)
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

### Do NOT run the full suite locally

The full `mix test` is **~9 min** and cannot be sped up by your machine: **217 of
441 test files are `async: false`**, so a measured run is
`Finished in 526.0s (57.4s async, 468.6s sync)` — ~89% strictly sequential on one
core. Running it blocks the edit loop while CI would run it in parallel, on the
faster runner, for free. Four full local runs in one session (2026-08-18) cost
~36 min and caught nothing CI would not have.

**Run locally before committing/pushing:**

```bash
mix format && mix credo --strict          # ~25s
mix dialyzer                              # ~30-35s with a warm PLT — do NOT skip
mix test <files-you-changed> test/lint/ --warnings-as-errors
```

- `test/lint/` is mandatory even on a targeted run — those are full-suite-only
  meta-tests (e.g. `notes_scope_lint_test.exs`) a targeted run otherwise skips.
- `--warnings-as-errors` because CI applies it to *test* code and the pre-push
  hook does not. Without it CI aborts **after a fully green run** with
  `Test suite aborted after successful execution due to warnings`, which reads
  like an infra failure rather than a code problem. Caveat: the flag only fails
  on warnings emitted while *compiling the files that run recompiled*, so with a
  warm `_build` an unchanged file emits nothing and the gate silently passes —
  introduce a warning, run once (red), re-run without editing, green. CI builds
  cold and catches it anyway. To actually reproduce CI, force the compile:
  `mix compile --force --warnings-as-errors`.
- Never run `mix dialyzer` and `mix test` concurrently — parallel dialyzer
  saturates the box, drops postgres connections, and fabricates failures
  scattered across unrelated modules. The tell is scatter; re-run alone.
- Never pipe a gate command through `tail` — `mix test | tail -25` returns
  *tail's* exit code (a fake 0) and truncates the failure block. Redirect to a
  file instead.

CI is the gate for the full suite and e2e. **Never merge on red** is unchanged.

See `docs/context/testing-strategy.md` for full strategy, tooling, and CI pipeline.

### A test must be able to fail

A green test is worth nothing until you know what makes it red. Three rules,
each written after a test in this repo proved nothing for an unknown number of
runs.

**1. A negative test's name must describe the exact thing being denied, and its
body must construct that exact case.**

`folders_controller_test.exs` had a case named *"404 when marker doesn't belong
to caller's vault"* whose body passed `Ecto.UUID.generate()` — an id belonging
to no vault at all. It proved the not-found path. A controller that looked
markers up globally and ignored the caller's vault entirely would have passed
it unchanged (#1562).

If the name says *another vault*, build a marker in another vault. If it says
*another user*, build another user. "Nonexistent" is a third, separate case.

**2. A test that reaches into another layer's internals must fail loudly when
the symbol it reaches for is gone.**

The e2e fan-out tests proved delivery by stubbing every alternate path to a
no-op. Every method name they stubbed had been retired from the plugin, and the
`typeof` guard skipped what was missing — so they stubbed **nothing**, and four
"TRUE fan-out proof" tests ran green with the feature dead (#1503, fixed in
#1559).

Prefer counting a call over disabling its alternatives: a pass-through wrapper
cannot break the code under test, and a rename leaves the counter at zero
instead of silently widening what satisfies the assert. Where a test must name
a foreign symbol, assert the symbol exists — `e2e/conftest.py`'s session-start
surface check is the pattern.

**3. For a scoping, auth, or boundary test, mutate the guard and watch it go
red before you trust it.**

Not tooling — by hand, once, at write time. Drop the predicate, run the one
file, confirm the failure, revert. #1562's vault-scoping case was verified this
way, and the mutation also revealed that the sibling cross-user case is
defended by RLS rather than by the query, so it stays green under the same
mutation. That distinction is invisible without mutating, and it is the
difference between two tests and one test plus decoration.

### Claims about the system carry their evidence

In PR bodies, issue comments and commit messages, label a claim by how you know
it: **measured** (with the number and where it came from), **deduced** (from
code you read — say so), or **assumed**. Do not promote a deduction to a fact
because it is probably right.

Worked example, both from one afternoon: *"api_only costs ~0 wall clock"* was
repeated from a comment in `verify.yml` and used to justify a decision; the
measured step times are 120s (e2e-crdt) and 86s (e2e-clerk) with a 0s follow-on
wait, so it was on the critical path the whole time. In the same window, *"a
failed fingerprint yields a green ci"* was stated as fact, and it is a sound
deduction from the workflow structure that has happened **0 times in 998 runs**.
Both were wrong to assert flatly; only one was wrong.

A comment in this repo is an assertion, not a measurement. Cite the run id.

## Quality Tooling

All quality lints are fatal in CI: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix sobelow --exit low --skip`, `mix dialyzer`. Configs at `.credo.exs`, `.sobelow-conf`, `.sobelow-skips`, `.dialyzer_ignore.exs`.

Deferred ratchets (future): `Readability.Specs` (forces `@spec` on every public function — ~225 outstanding) and `Design.DuplicatedCode` (13 outstanding).

**Run locally:**

```bash
mix format --check-formatted              # fast, gates immediately
mix compile --warnings-as-errors --force  # fast
mix credo --strict --mute-exit-status     # ~3s, strict mode (default in this repo)
mix sobelow --exit low --skip             # ~5s (--skip honours .sobelow-skips; MUST match CI)
mix dialyzer                              # ~32s warm; ~8 min the FIRST time in a new worktree (PLT re-key)
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

Design spec: Engram vault, `50 Engineering/_Superpowers Specs/` (logging taxonomy redesign, 2026-06-23).

## Build Phases — Status

| Phase | What | Status |
|-------|------|--------|
| 1: Scaffold | Phoenix app, Ecto schemas, RLS migrations, auth, health, Oban | shipped |
| 2: Notes CRUD | Upsert/read/delete/rename/changes, path sanitization | shipped |
| 3: Indexing | Markdown parser, Voyage embedder, Qdrant client, pipeline | shipped |
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

**Free $0 / Starter $7-mo ($70-yr) / Pro $14-mo ($140-yr).** Prices are stable;
the limit matrix is not.

**`Engram.Billing.LimitKeys` is the only source of truth for limits.** Read the
`@catalog` there. Do not restate the matrix here and do not trust a matrix you
find in any other doc.

This section used to carry a full feature table. Every line of it went stale
without anyone noticing, in three separate waves: the 2026-08-24 revision (Free
is 2 devices not 1, 24h not 12h cooldown, real-time sync on every tier, API keys
moved to Pro), the `ai_searches_per_day` consolidation that deleted six AI
meters, and pricing v3.1 (vaults 1/10/unlimited, attachments 1/10/50 GiB). It
told agents Starter had API write access for roughly a week after that became
Pro-only. A duplicated matrix is a matrix that drifts, so there is now one copy
and it is the code.

Decisions and rationale, including why each number is what it is:
`../engram-workspace/docs/context/pricing-tiers-v2-decisions.md`.

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

### Upgrades require zero operator action

A self-hoster upgrades by pulling a new image and restarting. Nothing else.
They skip releases, they do not read changelogs, and they will not run a
command for us. Every change must hold under that:

1. **No manual steps, ever.** No "run this mix task / rpc / SQL after
   upgrading", no env var that must be set for the upgrade to work, no
   required ordering of upgrades. If a change needs work done, the release
   does it on boot.
2. **Skip-release safe.** Any migration must be correct when applied in ONE
   batch together with every migration after it, starting from any older
   release. Expand/contract spread across releases protects the SaaS rolling
   deploy, but a self-hoster jumping N -> N+2 runs both halves back to back
   with no release in between.
3. **Backfills live in migrations, not app runtime.** A backfill done by app
   code in release N+1 never runs for someone who skips N+1. Put it in the
   migration, or make it a self-healing reconcile the app runs on its own
   (version stamp + reconcile, see the index self-heal pattern). The
   completion ledger for this: `docs/context/data-migrations-ledger.md`.
4. **Contract migrations assert their precondition.** Before dropping or
   tightening, check the thing it depends on actually happened (no NULLs
   left, no rows in the old shape) and raise if not. Fail loud on boot,
   never lose data quietly.
5. **New roles, grants and policies are created idempotently on boot**
   (`Engram.Release.prepare_database/0`) or by a role-guarded migration, so
   an upgrade from any release converges without operator help.

## Self-host preflight

Operators can preview what the next upgrade will do via:

    mix engram.preflight

Inside a running container:

    docker compose exec engram bin/engram rpc 'Engram.Release.Preflight.run()'

`Mix` is not part of the release, so this must go through
`Engram.Release.Preflight` — the older
`eval 'Mix.Tasks.Engram.Preflight.run([])'` form raised
`UndefinedFunctionError` and never worked in a container (#1311).

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

**Run the squawk gate locally — it is not a CI-only check.** `squawk` is not a
mix dep, so `lint_migrations.sh` exits "command not found" out of the box and it
is easy to conclude the check can only run in CI. It cannot; it just needs the
pinned binary and a scratch DB, which is one round trip cheaper than finding out
from a red `unit-tests` job (the squawk step runs *before* `mix test`, so a
failure there means the suite never ran at all):

```bash
curl -fsSL -o /tmp/squawk https://github.com/sbdchd/squawk/releases/download/v2.54.0/squawk-linux-x64
chmod +x /tmp/squawk
createdb squawk_lint   # fresh + empty; the script migrates it
git fetch -q origin main
SQUAWK_BIN=/tmp/squawk DATABASE_URL="postgresql://engram:engram@localhost:5432/squawk_lint" \
  MIX_ENV=test BASE_REF=origin/main bash priv/repo/lint_migrations.sh
```

Note `add :some_col, :string` renders `varchar(255)` and **fails**
`prefer-text-field` — resizing a varchar later takes an ACCESS EXCLUSIVE lock.
Use `:text` for anything without a real length constraint; Postgres stores them
identically.

## Context Docs

Grouped index into `docs/context/`. Each entry is a trigger → doc; read the doc itself for full detail.

**Architecture & Decisions**
- Changing chunking, tokenizing or what the keyword leg encodes (version stamps, the reconcile sweep, why "run X per vault after deploy" is a defect) → `docs/context/index-version-self-heal.md`
- Adding a backfill that must reach existing rows (`Engram.DataMigration`, completion ledger, `any_row?`, `:done` semantics, why not an operator command) → `docs/context/data-migrations-ledger.md`
- Elixir decision audit, library deps, infra checklist (partially superseded — read inline corrections) → `docs/context/elixir-architecture-decisions.md`
- RLS policy set (12 tenant tables, `api_keys_discovery`, `maintenance_all`), DB roles, `with_tenant`/`cross_tenant`/`maintenance()`/`skip_tenant_check` semantics → `docs/context/database-schema-rls.md`
- Adding a tenant table (needs its own `maintenance_all`), the `MAINTENANCE_DATABASE_URL` credential, why it is not BYPASSRLS → `docs/context/maintenance-db-role.md`
- `api_keys_discovery` policy (why `api_keys` stays in the tenant set; never roll back 20260918120000) → `docs/context/rls-cutover-breaks-api-key-auth.md`
- Retiring a column via expand/migrate-data/contract: never switch reads AND stop writes in one release → `docs/context/migrate-data-rollback-trap.md`
- Touching `RedactFilter` or logging near a vault path (drop the dep message, never scrub it; a raising primary filter disables ALL redaction node-wide) → `docs/context/log-redaction-boundaries.md`
- Writing a `use` macro that injects GenServer callbacks (`__before_compile__` defs lose to `defoverridable` defaults, silently) → `docs/context/before-compile-defoverridable-trap.md`
- Reading `TenancyGuard`'s boot line / re-verifying RLS enforcement on a deploy, or touching the probe (`:savepoint` outermost, sandbox can't test it, `reltuples`, `$1::regclass`) → `docs/context/rls-tenancy-probe-boot-log.md`
- Widening a column type without rewriting the table (`varchar[]` → `text[]` DOES rewrite; how to measure with relfilenode; when `# squawk-ignore-file` is justified) → `docs/context/migration-column-type-rewrites.md`
- All env vars by category → `docs/context/environment-variables.md`
- Rate limiter + `ai_searches_per_day` budget: BEAM-only (Hammer ETS + PubSub), zero Redis; why NOT Mnesia → `docs/context/rate-limiter-architecture.md`
- Adding a plan-limit / abuse gate as a plug, or a Free cap is not firing for a user clearly over it (a `request_path` guard cannot see MCP — every tool is one route, named in the JSON-RPC body) → `docs/context/mcp-bypasses-path-shaped-plugs.md`
- Proving a limit is actually WIRED (delete the gate line and re-run; a green suite means unproven) → `docs/context/mcp-bypasses-path-shaped-plugs.md`
- Reading a plan limit as a NUMBER, or a `-1` operator override made a user MORE restricted (`effective_limit/2` returns four spellings of "no limit" — use `Billing.cap/2` / `granted?/2`) → `docs/context/limit-sentinel-decoding.md`
- Adding a top-level route / Plug.Static mount / Phoenix scope / Cloudflare rule, and wondering if it can collide with a vault name (it cannot — vault URLs are `/v/:slug`; the old `@reserved_slugs` list is deleted) → `docs/context/vault-url-prefix-and-collision-surface.md`
- Making a route edge-cacheable, or adding a host/path to the Cloudflare Cache Rule (headers that vary by request poison a shared entry; `Vary` is ignored) → `docs/context/edge-cache-request-varying-headers.md`

**Sync & CRDT**
- Server-side sync protocol: seq change-log, `crdt_catchup_since` page builder, manifest, realtime channel (start here for sync work) → `docs/context/sync-protocol.md`
- Phoenix Channel events, conflict flow, plugin integration → `docs/context/channel-event-contract.md`
- Parallelising channel work (`Task.async_stream`) without starving the DB pool / killing the channel → `docs/context/channel-parallelism-db-pool.md`
- Unit-suite flake `could not checkout the connection owned by #PID` (sandbox shares the owner's connection — `pool_size` is NOT the lever) → `docs/context/channel-parallelism-db-pool.md`
- FanoutPacer hot/cold rules, why a note won't warm to HOT, testing it without flaking → `docs/context/fanout-pacer-hot-cold-and-testing.md`
- A web-app rename reverts to its old path, or you are adding a write path that moves a note's row → `docs/context/crdt-create-is-a-rename.md`
- Who owns note→path identity (`filemeta_v0` map is authoritative; claim before the row moves, outside any transaction) → `docs/context/crdt-identity-authority.md`
- The per-vault index room (`filemeta_v0`): wire, projection onto `notes.path_*`, why it drains with no off switch → `docs/context/crdt-index-room.md`
- A CRDT room won't go away, resident rooms climb, or tuning `CRDT_IDLE_EXIT_MS`/`CRDT_MAX_RESIDENT_ROOMS` → `docs/context/crdt-room-lifetime-and-drain.md`
- Background worker processed stale note content (facade vs `authoritative_content`) → `docs/context/worker-reads-stale-content-facade.md`
- Measuring CRDT doc bloat, deciding whether to reopen the flatten gate (#1707 closed: prod ratio 1.01), or reading the engram-crdt dashboard → `docs/context/crdt-bloat-measurement-traps.md`
- Note content doubled or interleaved, or the server holds a note TWICE (one-encoder invariant, frontmatter re-seed, flatten boundary #958) → `docs/context/crdt-lineage-doubling.md`
- Note version history, the outbox write path, adding a content-write path or an MCP write tool → `docs/context/note-revisions-history.md`
- Every `crdt_create` returns `create_failed` on a NEW vault, or a create leg drops a re-minted note id → `docs/context/crdt-create-cross-vault-id-reuse.md`
- `Repo.with_tenant/2` funs return bare values (or use `with_tenant!/2`), never `{:ok, _}` → `docs/context/with-tenant-return-wrapping.md`
- `y-indexeddb` `whenSynced` never resolves after `destroy()` → `docs/context/y-indexeddb-whensynced-destroy-hang.md`

**Indexing & Search**
- Oban indexing pipeline — dedup/debounce, retry, re-indexing → `docs/context/async-indexing-pipeline.md`
- Adding an Oban worker or cron, or code that marks rows for later processing (queue it when due; the queue throttles, crons are backstops; no two crons share a minute) → `docs/context/oban-scheduling-model.md`
- Stranded Qdrant points after a rename → delete race → `docs/context/qdrant-orphan-points-rename-delete-race.md`
- Qdrant payload indexes missing or rejected under strict mode (`ensure_collection/2` reconciles them on every boot) → `docs/context/qdrant-payload-indexes-strict-mode.md`
- An edit re-embeds far more chunks than it changed, or you are about to change how `split_text/2` packs chunks (boundaries cascade to the end of the heading section; paragraph-granularity looks like a free fix and is not) → `docs/context/chunk-boundary-stability.md`
- Measuring chunk reuse (repeated synthetic paragraphs + `MapSet` gives a wrong answer — match with multiplicity) → `docs/context/chunk-boundary-stability.md`
- Lingua NIF memory — `low_accuracy_mode` dial, the #891 OOM crash-loop → `docs/context/lingua-language-detection-memory.md`

**Billing & Pricing**
- Paddle MoR integration, webhook signature, event lifecycle, `custom_data`, affiliate flow, list pagination (stop on `has_more`, never `next`) → `docs/context/paddle-integration.md`
- `tier` values contract (default `free`, gate on `!active`) → `docs/context/billing-tier-frontend-contract.md`
- Attachment MIME/extension whitelist abuse defense (Pricing v2 §H) → `docs/context/attachment-mime-whitelist.md`
- Self-host silently drops attachments, or you are renaming/adding a boolean plan-limit key (`true` must always mean GRANTED) → `docs/context/self-host-capability-polarity.md`
- Changing a request shape an older plugin still sends, or raising the plugin version floor (mark the old path `compat(plugin)`, delete shims at the floor) → `docs/context/plugin-compat-shims.md`

**Auth, OAuth & MCP**
- Gating a Phoenix **channel** on onboarding/billing, or a paywalled account is syncing anyway (`RequireOnboarding` is a Plug and never runs on a socket; `user:` must stay UNGATED) → `docs/context/onboarding-gate-is-http-only.md`
- A test asserting paywall/tier/onboarding behavior passes but shouldn't (`config/runtime.exs` clobbers `billing_enabled` to false for the whole suite) → `docs/context/onboarding-gate-is-http-only.md`
- OAuth 2.1 + DCR on `/api/mcp` — wire flow, endpoints, token model, scopes → `docs/context/mcp-oauth.md`
- OAuth discovery advertises a `:80` port, or an MCP client can't reach the auth server behind edge-terminated TLS → `docs/context/oauth-discovery-urls-behind-edge-tls.md`
- What the MCP conformance suite does and does not prove (green means a lenient client coped; CIMD coverage is one vendor's document; OAuth stage runs on staging only) → `docs/context/mcp-conformance-suite-limits.md`
- CIMD documents are negotiated, DCR registrations are policed, don't share the changeset (the 2026-08-04 outage: every Claude connect died on `invalid_client`) → `docs/context/cimd-vs-dcr-validation-policy.md`
- A user who signed up INSIDE an MCP client's OAuth flow gets valid tokens and then 403 `onboarding_required` on every tool call forever (nothing in the grant path runs or links onboarding; `device_auth_controller.ex:21` is the existing precedent for relaxing it) → `docs/context/mcp-first-signup-onboarding-deadend.md`
- Auditing prod for users who never onboarded (`engram_audit_ro` is RLS-bound — a correlated subquery over `users` returns 0 for every row, silently; prod Loki ships warn+ only, so successful 2xx traffic is invisible) → `docs/context/mcp-first-signup-onboarding-deadend.md`
- Publishing to the official MCP registry (`server.json`, `mcp-publisher`, GitHub namespace auth), a personal `mcp-publisher login github` 403s on the org namespace (publish runs via OIDC on each release tag), or changing the listing title/description → `docs/context/mcp-registry-publishing.md`
- Submitting or updating the ChatGPT plugin directory listing (ZIP from `openai-plugin/`, never "Upload new", domain-challenge route, reviewer login via Clerk `bypass_client_trust`) → `docs/context/openai-plugin-directory-submission.md`
- Changing an MCP tool definition, or the TDQS lint job is red (regenerate `mcp-tools.json`; model-graded scoring is a hosted post-release report, not a CI job) → `docs/context/mcp-tdqs-baseline.md`
- Refresh-token rotation — leeway/overlap window, token-family reuse detection → `docs/context/refresh-token-reuse-detection.md`
- How `/settings/connections` + the onboarding checklist identify an OAuth/MCP client (slug attribution, the three hosting classes, HTTPS trust model) → `docs/context/connections-client-identity.md`

**Frontend / SPA**
- Frontend SPA map — bootstrap chain, runtime router, api/sync/realtime layer, viewer/editor (start here for web-app work) → `docs/context/frontend-architecture.md`
- Form controls and buttons: the one control height (`--spacing-control`), `<Input>` vs raw `<input>`, button role -> variant/size, the `<Button>` className rule → `docs/context/form-controls.md`
- Spot-checking the ten web-app translations in a browser (language switch and auto-detect, surface checklist, per-locale native-speaker review list, known gaps) → `docs/context/webapp-i18n-spot-check.md`
- Wikilink (`[[...]]`) → note resolution in the SPA viewer → `docs/context/spa-wikilink-resolution.md`
- Footnotes in the CM6 editor: build vs adopt → `docs/context/codemirror-footnote-options.md`
- Matching Obsidian's real Properties panel CSS/geometry → `docs/context/obsidian-properties-parity.md`
- A Radix menu item that opens an inline editor (use `modal={false}`, or the blur-committing input fights the menu) → `docs/context/radix-modal-menu-vs-blur-committing-input.md`
- An e2e locator or screen reader stopped seeing a string after you swapped text for an input/icon → `docs/context/text-to-control-breaks-locators-and-a11y.md`
- Who is using Engram: activity events, the PostHog surfaces, real DAU → `docs/context/product-activity-analytics.md`
- Touching `frontend/src/analytics/`, the `/ph` proxy, or bumping `posthog-js` (SDK-added `$current_url` leaks vault slugs; `sanitize_properties` is deprecated and fails open) → `docs/context/posthog-instrumentation-traps.md`
- Web app 404s every vault-scoped call (folders/attachments/notes), or a client-only fixture id poisoned persisted `activeVaultId` → `docs/context/stale-active-vault-404s.md`
- `window.__ENGRAM_CONFIG__` first-paint state injection pattern → `docs/context/spa-state-injection.md`
- Login boot perf (PR #842) — chunk-size measurement, VLQ-decode under hidden sourcemaps → `docs/context/frontend-login-boot-perf.md`
- Folder-tree `rebuildTree()` triggers, optimistic move/delete/duplicate → `docs/context/folder-tree-optimistic-rebuild.md`
- The sidebar tree flashes empty every few minutes, or you are writing query options a caller reads via `getQueryData`/`fetchQuery` (no observer → `gcTime` deletes the entry, and `invalidateQueries` won't refetch it) → `docs/context/folder-tree-optimistic-rebuild.md`
- Adding a cache that holds note/folder data, or wondering why a sidebar view has no key of its own (one `['vault-tree']` query, everything else is a `select` view of it) → `docs/context/folder-tree-optimistic-rebuild.md`
- A web-app folder delete reverts ~1s later, or you are touching any folder route (a folder is EITHER a `kind="folder"` marker row OR derived from the paths of the notes/attachments inside it) → `docs/context/derived-vs-marker-folders.md`
- Adding a `?flag=true` query param to a controller (nothing casts query params here; `type: :boolean` in the OpenAPI op silently no-ops `?flag=1`) → `docs/context/derived-vs-marker-folders.md`
- Mobile keyboard toolbar — why it hides on some phones, the decoy Yjs UndoManager, caret-after-insert → `docs/context/mobile-editor-toolbar.md`
- Writing a CM6 live-preview decoration (lezer reads `[!type]` as a Link; one highlight tag serves many nodes; `syntaxTree` is lazy) → `docs/context/codemirror-live-preview-extensions.md`
- A route guard or view acts on state that mutations definitely updated (user bounced back to a completed onboarding/wizard step; loop only a full page reload escapes) → `docs/context/bootstrap-seed-cache-dual-authority.md`
- Adding a shadcn/Base UI component (popup untappable inside a Radix sheet on mobile, field unnamed while the list is open, SPA-wide 504 `Outdated Optimize Dep` after a `bun remove`, `fireEvent.click` won't open a combobox) → `docs/context/shadcn-combobox-adoption.md`

**Issue tracker**
- An old issue's description contradicts the code, or you are triaging a stale backlog (`Refs #N` drift + the detection recipe) → `docs/context/backlog-refs-drift.md`

**Testing & CI**
- Full test strategy, ExUnit tooling, CI pipeline → `docs/context/testing-strategy.md`
- CI pipeline & gating — what runs vs what gates, post testing-architecture migration → `docs/context/ci-pipeline-gating.md`
- Running the ExUnit suite locally against Docker Postgres → `docs/context/local-backend-testing.md`
- `Vault not registered after 15s` E2E diagnostic ladder — don't just bump the timeout → `docs/context/e2e-vault-registration-diagnostics.md`
- `Application.put_env` in `async: true` tests is a flake source (fix the mutator, or route the read through `Engram.ServiceConfig` per-process overrides) → `docs/context/exunit-application-env-races.md`
- Writing a test that proves a query is tenant-scoped (only INSERT raises; the suite connects as a SUPERUSER; use `Engram.RlsCase` + a zero-rows CONTROL test) → `docs/context/rls-enforcement-testing-traps.md`
- An e2e assertion counts something vault-wide, or a test's failure count refuses to move across product fixes (the e2e vault is session-scoped and shared by ~110 tests) → `docs/context/e2e-session-vault-scoping-trap.md`
- Several unrelated `e2e-crdt` tests fail in one run (live-binding + seq-gap-heal + orphaned-claim + web-to-obsidian): check whether both Obsidian instances died mid-run before counting N bugs → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- A CDP call starts returning `[Errno 111] Connection refused`, or a "content never propagated" 120s timeout while the backend log stays healthy: read `obsidian-stderr-*.log` / `host-forensics.log` for the OOM kill → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- Deciding whether a red e2e run is a real regression (same test passing on the SAME sha in a sibling run; check the pinned PLUGIN sha too) → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- Why `prebuild-mix` recompiled everything despite cache hits (absolute-path compile manifest) → `docs/context/ci-mix-compile-cache-runner-path.md`
- Bun lifecycle-script trust model, `trustedDependencies`, the pngquant CI flake (#975) → `docs/context/bun-postinstall-trust.md`
- Red `e2e-clerk`: which failures are REAL bugs vs load vs a lying oracle → `docs/context/e2e-clerk-failure-taxonomy.md`
- All e2e modal tests fail "Modal option not found" (stranded sync-preview modal cascade) → `docs/context/e2e-sync-preview-modal-cascade.md`
- Playwright clicks hang / headless Chromium renders no frames on the dev box → `docs/context/headless-chromium-no-raf-playwright.md`
- Changing the headless CRDT test tier, or `main.ts`'s CRDT lifecycle (the headless harness must mirror it) → `docs/context/headless-harness-mirrors-main-ts.md`
- Testing-architecture migration record: report-only e2e, the flake ledger, why the gate is deterministic → `docs/context/testing-architecture-migration.md`
- The e2e harness is an API consumer. Before changing any endpoint contract (caps, status codes, param semantics), grep `e2e/` and `frontend/e2e/`, not just `frontend/src` and the plugin. A 500-id 422 cap on batch-delete once broke e2e teardowns that send 1000+ ids. Remaining caps: notes `batch_upsert` 500 (encrypt + CRDT merge per entry), attachments `batch_delete` 500.
- Adding a fast mode to a fingerprinted CI job, widening a cache restore-key, or a job reads a file in no fingerprint group → `docs/context/ci-fingerprint-markers.md`
- CI registry `:5001` refused or `manifest unknown` after a prune, or changing CI registry retention/GC (marker window < image window, never GC near a push) → `docs/context/ci-registry-down-during-appdata-backup.md`
- A `Post <name>` cache step takes 10-15 min, or adding a cache / image-push target in CI (runs-on/cache only; NO_PROXY for push hosts) → `docs/context/github-cache-upload-cliff.md`
- Touching sobelow or `.sobelow-skips`, or regenerating skips after a line shift (fingerprints defend locations not provenance; `rm` before `--mark-skip-all`) → `docs/context/sobelow-silent-no-op-and-fingerprint-skips.md`

**Deploy & Infra**
- AWS ECS deploy, backups, observability, security checklist → `docs/context/deploy-prod.md`
- `git push` of a `release-v*` tag is rejected as `already exists` (release-please cuts the tag itself on release-PR merge), or `deploy-prod.yml` / `terraform apply` is green and you are about to call prod deployed (neither waits for the ECS rollout), or verifying a rollout/WORKER tier without AWS credentials, or Loki's newest line stopped after a deploy → `docs/context/deploy-prod.md`
- Checking whether a frontend change shipped by grepping the deployed SPA, or a `version` field that won't move after a deploy (the entry bundle proves nothing — routes are lazy chunks; trust `build_sha`) → `docs/context/frontend-ship-verification-bundle-grep.md`
- Expecting a main merge to move prod frontend traffic (`deploy-frontend` only uploads a zero-traffic version; only `frontend-promote.yml` shifts traffic) → `docs/context/frontend-ship-verification-bundle-grep.md`
- Launch-minimum DR runbook — RDS snapshots, S3 versioning, Qdrant reindex fallback → `docs/context/disaster-recovery.md`
- Why `_build` cache mount across Docker RUN steps ships stale beams → `docs/context/docker-build-cache-pitfalls.md`
- Local dev loop, hot reload, IEx tricks → `docs/context/dev-iteration-loop.md`
- Local Qdrant dies mid-upsert with `Req.TransportError: socket closed` while `docker inspect` still says healthy (SIGILL, not OOM — this host has no AVX2; read `RestartCount`, not `oom`) → `docs/context/local-qdrant-sigill-no-avx2.md`
- PG18/UUIDv7 prod crash-loop root cause — in-place engine bump vs specced taint+recreate; `verify_schema_baseline/0` guard → `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`
- `mjml` vs `lingua` rustler_precompiled version conflict — pin override → `docs/context/rustler-precompiled-nif-conflict.md`
- Worktree compile fails on a dep module "not available" (`expo_po_parser`, `Hammer`); `mix deps.compile X` without `--force` silently no-ops; hardlinked `deps/` can omit yecc/leex-generated beams → `docs/context/worktree-deps-artifact-staleness.md`
- `git push` from a worktree hangs or is rejected at the pre-push gates, `mix` reports `erts-14`/OTP 26, or `:opentelemetry` fails with `missing_module,opentelemetry_sup` (bare push runs the gates on the system OTP; always `mise exec -- git push`) → `docs/context/worktree-push-otp-mismatch-rebar-dep.md`
- ExAws KMS traps (key-first args, manual base64, scope creds to `:ex_aws, :kms` or S3 auth silently breaks), plus the Tier-4 / Phase F provider-routing roadmap → `docs/context/aws-kms-provider-integration.md`

**Encryption**
- Runbooks: per-user DEK rotation (T3.7) + half-state recovery, master-key rotation (staging/self-host only; prod is KMS) → `docs/context/encryption-operations.md`. The content-hash HMAC backfill was removed 2026-10-06 (prod at zero; see "Pruned" in `docs/context/data-migrations-ledger.md`)
- Invalid UTF-8 at rest (bytea bypasses PG validation) → `Jason.encode` 500 at every JSON egress; fix + backfill task → `docs/context/invalid-utf8-at-rest-json-500.md`

**Perf & Quality**
- Read-path decrypt perf — parallel_map economics, when it helps vs hurts → `docs/context/read-path-decrypt-perf.md`
- Perf caches + invalidation contracts (2026-06-12 audit wave) → `docs/context/perf-caching-invalidation.md`
- Replacing hand-rolled code with a shared helper (consolidating a PARSER silently drops accepted input shapes no test names — CRLF frontmatter read as "no frontmatter"), or a log metadata key built inside a helper that Credo cannot see → `docs/context/consolidation-drops-undocumented-tolerances.md`

## Superpowers spec docs → Engram vault (overrides the skill default)

When `superpowers:brainstorming` produces a design/spec doc, save it to the **Engram vault** at `50 Engineering/_Superpowers Specs/YYYY-MM-DD-<topic>-design.md` via the engram MCP (`set_vault` → Engram `4c2057f9-a6cb-4e5e-9b4e-7ac50fb77c35`, `create_note`/`write_note`, then `set_vault()` to reset) — **not** to `docs/superpowers/specs/`. Specs are durable design rationale, so they live in the vault (searchable, dogfoods engram). This user instruction takes precedence over the skill's local-save step.

**Plans stay repo-local.** `superpowers:writing-plans` output is an ephemeral implementation checklist — keep it in `docs/superpowers/plans/` as the skill specifies; do not route plans to the vault.

## Life OS
project: engram
goal: income
value: financial-freedom
worklog_vault: Engram
worklog_path: 90 Work Log/todd
