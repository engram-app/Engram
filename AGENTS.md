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
| Oban Workers | `lib/engram/workers/`, `lib/engram/billing/workers/` | EmbedNote, ReconcileEmbeddings, DataMigrationsRunner, WarmCrdtHeads, DeleteNoteIndex, RotateUserDek, RotateUserMasterKey, AccountExport, InactivityCleanup, MigrateUserProvider, OrphanSweep, AttachmentBlobGC, CleanupVault, VaultDeletedEmail, CleanupDeviceAuthWorker, OriginAbuseSweep, PaddleReconcile, OverrideExpirySweep |

### Key Patterns

- **OTP supervision** — `one_for_one`: Channel crashes don't affect Oban, and vice versa
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (**no Redis/Valkey anywhere** — BEAM handles PubSub/caches natively; clustered SaaS prod runs a distributed ETS + Phoenix.PubSub rate limiter, self-host plain ETS, and the durable daily search cap is a Postgres token bucket — ElastiCache removed 2026-06-21)
- **PostgreSQL RLS** — DB-enforced tenant isolation via `SET LOCAL app.current_tenant`. `Repo.prepare_query` raises on unscoped queries. See `docs/context/database-schema-rls.md`
- **Two DB roles** — `engram_owner` (migrations) and `engram_app` (runtime, subject to RLS)
- **Behaviour-based adapters** — `Engram.Embedder` behaviour for Voyage/Ollama
- **Async indexing, sync note storage**: note upsert returns immediately; embedding queued via Oban (30s settle debounce, 5m ceiling, dedup). See `docs/context/async-indexing-pipeline.md`
- **Rust NIFs** (`native/engram_native`, rustler, dirty CPU): the keyword encoder (tokenize + Snowball + HMAC + BM25), 15-43x faster than the Elixir it replaced. **Default to a Rust NIF for CPU-bound pure work** (parsing, tokenizing, hashing, regex, encoding over binaries); keep Elixir for orchestration and I/O. Every NIF follows the memory standard (BEAM allocator, per-call native peak, `[:engram, :nif, :call, :stop]`, unaccounted-RSS poll). Rules, test patterns and the next candidates (markdown chunker, link parser): `docs/context/native-nifs.md`
- **Index changes heal themselves** — a change to chunking or keyword encoding must reach existing notes with NO operator step (self-hosters never run one). Bump `Engram.KeywordIndex` `@version` (keyword-only, free) or `@chunker_version`; `ReconcileEmbeddings` sweeps stale stamps. See `docs/context/index-version-self-heal.md`
- **Per-request query budget + `Engram.Cache`** — every hot path has an exact query count pinned in `test/engram/query_budget_test.exs`; node-local caches are `Engram.Cache` registry entries (trigger NOTIFY eviction), `Repo.with_tenant` is 3 round trips, side effects go in `Repo.after_commit/1`. Adding a cache, reading a budget failure, next targets: `docs/context/request-query-budget.md`
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

## Web-app translations: translategemma is the translator

Every catalog entry in `frontend/src/i18n/locale/*.ts` comes from `translategemma:12b` on FastRaid's Ollama via `bun run i18n:translate`. Agents do not write translations themselves.

- **Adding or editing a UI string:** wrap it (`t`, `tn`, `msg`, `<Trans text>`), then run `cd frontend && I18N_OLLAMA_URL=http://10.0.20.214:11434 bun run i18n:translate`. It translates only the keys a catalog lacks and drops orphans, in minutes. Commit the catalog diff in the same PR. If Ollama is unreachable, merge without catalogs: the `i18n-translate.yml` bot PR fills them after merge (English is the designed fallback until then).
- **Never hand-translate or translate with your own model.** The pipeline holds the glossary and per-language register (de/es/fr/it informal, ru formal) fixed. Hand edits drift, and the next redo overwrites them. To fix a bad translation, change the profile (`src/i18n/translate-profile.ts`) or a check in the core, then rerun. Glossary terms are the one exception: they come from Obsidian's official translations and are edited by hand.
- **No version to bump.** `locale/state.json` stores a fingerprint of the prompt, the profile and the Ollama model digest per locale. Change any of them and the next run (local or the CI bot) redoes that locale. A new check heals failing entries on the next run (`invalidKeys`).
- **The pipeline is shared:** `src/i18n/core/` is the canonical copy of the core the plugin and marketing repos vendor byte for byte. After editing it, run `make i18n-core-sync` from the workspace and commit in all three repos (`core/README.md`). A vendored copy edited in place fails its `core-header` test.
- **Product and plan names are never translated** ("Engram", "Obsidian", "Starter", "Pro", "Open Knowledge Format"; add new ones to `BRANDS` in `translate-profile.ts`). "Free" is translated: it describes the price.
- **A key the model cannot translate** is recorded in `state.json` `failed` with the day it first failed; the gate tolerates it while listed (English shows meanwhile). The script and the nightly bot fail once it is stuck past 14 days: reword the source string or fix the prompt.
- **Adding a language:** copy the glossary terms for it from Obsidian's official translations (`obsidianmd/obsidian-translations`) into the new catalog first, then add it to `LOCALES`/`LOCALE_NAMES` (`src/i18n/locales.ts`), `SPECS` (`src/i18n/translate-profile.ts`) and `vendor-locales.ts` (Clerk + Paddle), then run `bun run i18n:translate --locale <code>`.
- **A counted string is a plural with `{count}`:** `tn()` fills and locale-formats `{count}` itself, so never pass a formatted number under another name (`{n}`); the plural sampler needs `{count}` (`catalog-quality.test.ts` "source strings can be translated").
- **User-facing text is typed, and tsc enforces it.** `t`/`tn` return `UIText`; UI text props and `notify()` (the only toast API; importing sonner's `toast` is a lint error) accept only `UIText`. Text we show as-is (a server/Clerk error message, user data, a brand name) goes through `untranslated(text)`, the one reviewable exception: grep it. Module-scope label arrays hold `msg()` keys typed `MsgKey`, rendered with `t()`. Never widen a `UIText`/`MsgKey` field back to `string` to make an error go away; a new user-facing prop is `UIText` from day one.
- **Never suppress the gates:** `noJsxLiterals` (Biome), `keys.test.ts` and `catalog-quality.test.ts`. A genuinely untranslatable string (brand, symbol, code format) goes on the rule's `allowedStrings` in `biome.json`, or on the attribute test's allowlist.
- Full design, checks and failure modes: `docs/context/webapp-i18n.md`.

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

## Database changes are autonomous — the rule

Every database change, schema or data, must reach every install with **no
human step**: no label to pick, no command to run after deploying, no env
var to set. A SaaS deploy and a self-hoster pulling an image
get the same result by booting the new release. There are no migration phase
labels; PRs that touch `priv/repo/migrations/` need nothing but green CI.

What that means in practice:

1. **Schema changes apply on boot.** The migration runs as part of the release
   (`Engram.Release`), converges from any older release, and needs nothing
   from the operator. Prefer additive changes (nullable column, new table,
   `CREATE INDEX CONCURRENTLY`).
2. **Backfills self-heal.** Do not ask anyone to run a task. Put the backfill
   in the migration, or make it a `data_migrations` ledger entry that one
   hourly runner finishes and then stops running
   (`docs/context/data-migrations-ledger.md`); index changes use a version
   stamp plus reconcile.
3. **Dropping or renaming something code still reads breaks the previous
   release** while a deploy is rolling. Ship the code that stops using it
   first, then the migration that removes it. The `migration-gates` CI job
   enforces this: it extracts what a new migration drops or renames (up
   direction only) and fails if `lib/` still references it. A raw-SQL
   `DROP COLUMN|TABLE` in `execute/1` cannot be checked, so use Ecto's
   `remove`/`drop`, or add a `# safety_assured: "reason"` comment.
4. **A migration must apply on top of the previous release's schema.** The
   same job applies new migrations onto the last `release-v*` tag's schema.

## Data DML in migrations — FORCE RLS trap

Raw `UPDATE`/`DELETE`/`INSERT` against a tenant table in a migration silently
touches **zero rows on prod**: the migrator (`engram_admin`) owns the tables
but has no BYPASSRLS, migrations set no `app.current_tenant`, and FORCE RLS
binds owners too — dev/CI superusers mask it. Wrap the DML in
`ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` / re-`FORCE` and add a
fail-loud rowcount assertion. `migration_rls_lint_test.exs` enforces this;
full pattern + rationale in `docs/context/migrations-force-rls-data-dml.md`.

## Forbidden in migrations

Squawk (run via `priv/repo/lint_migrations.sh`) already hard-fails on:

- `DROP COLUMN`, `DROP TABLE` — only after a release that stops using it (see the rule above); name the file `*_drops.exs` so Squawk defers the drop rules to the CI reference check
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

Column-type changes and destructive DDL still follow the rule above.

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

Squawk markers scope to their own file (each new migration is linted
separately). Prefer the narrow one:

```elixir
# squawk-ignore: require-concurrent-index-creation
# New empty table: a non-concurrent index cannot block anything.
```

The marker line holds rule names only; put the reason on the next line.
`# squawk-ignore-file` (no lint at all) is for DDL squawk cannot parse.
Because each file is linted alone, an index on a table created in an EARLIER
new migration is no longer exempt (squawk only exempts same-file tables):
mark it `# squawk-ignore: require-concurrent-index-creation`.

## Migration self-host story

We ship the same migrations to AWS ECS (rolling, zero-downtime) and to
self-hosters (Unraid / engram.ax, container-down → migrate → container-up).
Self-hosters get downtime for free, and the same source-side gates protect
them because the unsafe SQL never enters the migration files they pull.

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
   release. A change split across releases (stop using, then drop) protects
   the SaaS rolling deploy, but a self-hoster jumping N -> N+2 runs both
   halves back to back with no release in between.
3. **Backfills live in migrations, not app runtime.** A backfill done by app
   code in release N+1 never runs for someone who skips N+1. Put it in the
   migration, or make it a self-healing reconcile the app runs on its own
   (version stamp + reconcile, see the index self-heal pattern). The
   completion ledger for this: `docs/context/data-migrations-ledger.md`.
4. **Destructive migrations assert their precondition.** Before dropping or
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

The output lists pending migrations, whether each is
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
- CI jobs: `.github/workflows/verify.yml` — `migration-gates` (contract references, N-1 compat), `migrations-immutable`, `Lint new migrations (squawk)`, `Test new migrations roll back (ecto.rollback)`

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

The full trigger → doc index is **`docs/context/INDEX.md`** (not auto-loaded). A prompt hook injects the lines that match your prompt; before non-trivial work in an area, also grep it: `grep -i <keyword> docs/context/INDEX.md`.
- Areas covered: Architecture & Decisions; Sync & CRDT; Indexing & Search; Billing & Pricing; Auth, OAuth & MCP; Frontend / SPA; Issue tracker; Testing & CI; Deploy & Infra; Encryption; Perf & Quality.
- New doc: add its trigger line to `docs/context/INDEX.md`, never to this file.

## Superpowers spec docs → Engram vault (overrides the skill default)

When `superpowers:brainstorming` produces a design/spec doc, save it to the **Engram vault** at `50 Engineering/_Superpowers Specs/YYYY-MM-DD-<topic>-design.md` via the engram MCP (`set_vault` → Engram `4c2057f9-a6cb-4e5e-9b4e-7ac50fb77c35`, `create_note`/`write_note`, then `set_vault()` to reset) — **not** to `docs/superpowers/specs/`. Specs are durable design rationale, so they live in the vault (searchable, dogfoods engram). This user instruction takes precedence over the skill's local-save step.

**Plans stay repo-local.** `superpowers:writing-plans` output is an ephemeral implementation checklist — keep it in `docs/superpowers/plans/` as the skill specifies; do not route plans to the vault.

## Life OS
project: engram
goal: income
value: financial-freedom
worklog_vault: Engram
worklog_path: 90 Work Log/todd
