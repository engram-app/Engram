# AGENTS.md: Engram backend agent and contributor guide

> Canonical guide for AI coding agents (Claude Code, Copilot, Cursor, Codex,
> Gemini) and humans. `CLAUDE.md` is a symlink to this file; edit **this** file.
> It loads into every agent session, so keep it short: long-form material lives
> in `docs/context/`. CI gates enforce correctness; this doc shortens the loop.

Engram is an AI-powered personal knowledge base built on Obsidian: it stores a
user's vault, indexes it, and makes it queryable by any AI assistant via MCP.
This repo (`engram-app/Engram`) is the Elixir/Phoenix backend plus the React SPA
in `frontend/` (see `frontend/CLAUDE.md` for UI rules). The Obsidian plugin is
`engram-app/Engram-obsidian`. For cross-repo work, the `engram-app/engram-workspace`
repo cloned as a sibling (`../engram-workspace/`) gives shared context.

Issues and TODOs live in GitHub Issues (`gh issue list`), never in this file,
`docs/`, or TODO.md files (CI forbids TODO*.md).

## Layout

| Path | What |
|------|------|
| `lib/engram/` | Contexts: notes, indexing, search, auth, billing (Paddle), crypto, MCP server |
| `lib/engram_web/` | Endpoint, router, controllers, channels (real-time sync), plugs, OAuth |
| `lib/engram/workers/` | Oban background jobs |
| `native/engram_native` | Rust NIFs (rustler) for CPU-bound pure work |
| `priv/repo/migrations/` | Ecto migrations (immutable once merged) |
| `frontend/` | React + Vite + Tailwind + shadcn/ui SPA |
| `test/`, `e2e/` | ExUnit tests; Python E2E against a real Obsidian |
| `docs/context/` | Repo knowledge base, indexed by `docs/context/INDEX.md` |

Stack: Phoenix Channels + PubSub for sync (no Redis anywhere), Postgres with
RLS + Oban, Qdrant for vectors, Voyage AI embeddings (Ollama for local/self-host),
S3 or local disk for attachments. Component map, patterns and data flow:
`docs/context/backend-architecture.md`. Decision audit:
`docs/context/elixir-architecture-decisions.md`.

## Local development

`git worktree add <path> -b <branch> origin/main` fires `.githooks/post-checkout`,
which hardlinks `deps/`, `_build/` and `frontend/node_modules/` from the main
checkout, so the first compile takes seconds. Work in a worktree, not on `main`.

```bash
docker compose up --build   # Elixir + Postgres + Qdrant + Ollama (MinIO via --profile s3)
mix deps.get && mix ecto.setup && mix phx.server   # outside Docker: http://localhost:4000
cd frontend && bun install && bun run dev          # Vite on :5173, proxies to Phoenix
```

Outside Docker you need Postgres 18+ (`uuidv7()`), Qdrant, and Rust via rustup
(`mix compile` builds `native/engram_native`). Env vars:
`docs/context/environment-variables.md`. Local test DB: `docs/context/local-backend-testing.md`.

## Testing

**Tests are the spec. If a test fails, fix the app, not the test.**

Do NOT run the full `mix test` locally: it takes ~9 min, mostly sequential, and
CI runs it for free. Before pushing run:

```bash
mix format && mix credo --strict
mix dialyzer                                         # not in the pre-push hook; CI runs it
mix test <files-you-changed> test/lint/ --warnings-as-errors
```

- `test/lint/` is mandatory even on a targeted run (meta-tests a targeted run skips).
- `--warnings-as-errors` matches CI; with a warm `_build` it can pass silently, so
  use `mix compile --force --warnings-as-errors` to reproduce CI.
- Never run `mix dialyzer` and `mix test` concurrently (fabricated DB failures).
- Never pipe a gate through `tail`: you get tail's exit code. Redirect to a file.
- A test must be able to fail: negative tests build the exact denied case, and
  scoping/auth tests are checked once by mutating the guard and watching it go red.
- In PRs and issues, label claims **measured** (number + source), **deduced**, or **assumed**.

E2E: `python3 -m pytest e2e/tests/ -v` against the CI stack. Full strategy, the
"test must fail" rules with examples, and lint tooling:
`docs/context/testing-strategy.md`. RLS tests prove nothing as a superuser: read
`docs/context/rls-enforcement-testing-traps.md` first.

## Hard rules

### Database changes

Every schema or data change must reach every install (SaaS and self-host) with
**no human step**: no label, no post-deploy command, no required env var. A
self-hoster upgrades by pulling an image and restarting, and may skip releases.

1. **Migrations are immutable once merged** (`migrations-immutable` CI job). Fix forward.
2. **Schema changes apply on boot** (`Engram.Release`). Prefer additive changes
   (nullable column, new table, `CREATE INDEX CONCURRENTLY`). Use `:text`, not `:string`.
3. **Expand, then contract.** Ship the code that stops reading a column/table
   first, then the migration that drops it (name it `*_drops.exs`). The
   `migration-gates` job fails a drop that `lib/` still references, and applies
   new migrations onto the last `release-v*` schema. Every migration must also
   be correct when a skipping self-hoster applies it in one batch with later ones.
4. **Backfills self-heal**: in the migration or as an `Engram.DataMigration`
   ledger entry (`docs/context/data-migrations-ledger.md`). Index changes bump a
   version stamp (`docs/context/index-version-self-heal.md`). Destructive
   migrations assert their precondition and raise.
5. **FORCE RLS trap:** raw DML on a tenant table in a migration touches zero rows
   in prod. Wrap in `NO FORCE ROW LEVEL SECURITY` / re-`FORCE` with a rowcount
   assertion (`docs/context/migrations-force-rls-data-dml.md`).
6. **Background queries bound rows READ**, not rows returned: walk id windows with
   `Engram.Backfill.IdWindows`, never `timeout: :infinity`.
7. Squawk (`priv/repo/lint_migrations.sh`) hard-fails unsafe DDL; read its message.

Long form (squawk locally, `# safety_assured:`, PG18 patterns, baseline regen,
preflight, tooling locations): `docs/context/migrations-playbook.md`.

### Security boundaries

- **RLS is the tenant boundary.** Tenant queries run in `Repo.with_tenant`
  (`SET LOCAL app.current_tenant`); `Repo.prepare_query` raises on unscoped ones.
  Two runtime roles: `engram_owner` (migrations) and `engram_app` (subject to RLS).
  See `docs/context/database-schema-rls.md`. Adding a tenant table:
  `docs/context/maintenance-db-role.md`.
- **Never log sensitive values in a message string.** `RedactFilter` scrubs
  metadata keys only. Build metadata with
  `Engram.Logger.Metadata.with_category(level, category, kw)` and add new keys to
  the allowlist in `config/config.exs`. Full conventions:
  `docs/context/logging-conventions.md`; redaction:
  `docs/context/log-redaction-boundaries.md`.
- Every client path goes through `Engram.Notes.PathSanitizer.sanitize/1`; auth is Clerk JWT, API keys, and MCP
  OAuth 2.1 (`docs/context/mcp-oauth.md`). Encryption ops:
  `docs/context/encryption-operations.md`.

### Other rules

- **No version bumps in feature PRs.** release-please owns versions and the changelog.
- **Plan limits:** `Engram.Billing.LimitKeys` `@catalog` is the only source of truth.
  Never restate the limit matrix in a doc. Self-host (no `PADDLE_API_KEY`) has no billing.
- **CPU-bound pure work defaults to a Rust NIF**; keep Elixir for orchestration
  and I/O (`docs/context/native-nifs.md`).
- **Hot paths have pinned query budgets** (`test/engram/query_budget_test.exs`,
  `docs/context/request-query-budget.md`).
- **Translations come from the translategemma pipeline**, never hand-written:
  wrap the string, run `cd frontend && I18N_OLLAMA_URL=<ollama-url> bun run i18n:translate`
  (the team Ollama runs on FastRaid, the LAN server at 10.0.20.214:11434), or
  let the `i18n-translate.yml` bot PR fill catalogs after merge. Product and plan
  names are never translated. Rules: `docs/context/webapp-i18n.md`.

## CI and deploy

- `.github/workflows/verify.yml` runs on every push: lint, unit tests, migration
  gates, e2e. What gates vs report-only: `docs/context/ci-pipeline-gating.md`.
  Never merge on red.
- Prod release: merge release-please's `chore(main): release X.Y.Z` PR. It cuts
  the `release-v*` tag itself; `deploy-prod.yml` then opens an engram-infra PR,
  and prod moves when that merges. A green workflow does not mean the ECS rollout
  finished: `docs/context/deploy-prod.md`. Staging follows `main` automatically.
- Commits are signed and use conventional prefixes (`feat:`, `fix:`, `docs:`).

## Where docs live

- **Before non-trivial work in an area, grep the index:**
  `grep -i <keyword> docs/context/INDEX.md`.
- A new context doc gets its trigger line in `docs/context/INDEX.md`, never here.
- Implementation plans: `docs/superpowers/plans/`. Design specs: the Engram vault,
  `50 Engineering/_Superpowers Specs/`.
- Product pricing rationale: `../engram-workspace/docs/context/pricing-tiers-v2-decisions.md`;
  billing integration: `docs/context/paddle-integration.md`.
