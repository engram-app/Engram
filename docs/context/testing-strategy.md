# Context Doc: Testing Strategy

_Last verified: 2026-06-12_

## Status
Working — ExUnit tests cover business logic and HTTP contract via ConnCase. E2E tests verify real Obsidian sync workflows against Docker stack.

## What This Is
Testing philosophy, test layers, tooling, and CI pipeline for the Engram Elixir/Phoenix backend.

## Philosophy

**Tests are the spec. If a test fails, fix the app — not the test.**

## Test Layers

| Layer | Location | Command | What it tests | Infra needed |
|-------|----------|---------|---------------|--------------|
| **Unit/ConnCase tests** | `test/` | `mix test` | Business logic, HTTP contract, auth, RLS, plugs | Postgres (Ecto.Sandbox) |
| **E2E tests** | `e2e/tests/` | `python3 -m pytest e2e/tests/ -v` | Real Obsidian sync: push/pull, Channels, conflicts, multi-user | CI stack + Obsidian |
| **E2E helper unit tests** | `e2e/unit_tests/` | `python3 -m pytest e2e/unit_tests/ -v` | SQL injection prevention in cleanup helpers | None |

## Elixir Testing Stack

| Tool | Purpose |
|------|---------|
| **ExUnit** | Test framework |
| **Ecto.Adapters.SQL.Sandbox** | Per-test DB transactions (auto-rollback) |
| **ExMachina** | Test data factories |
| **Mox** | Behaviour-based mocks (embedder, Qdrant client) |
| **Bypass** | HTTP mock server (for Voyage AI, Qdrant API) |

Key advantage: `async: true` runs tests in parallel with per-test DB transactions. No cleanup needed.

## Running the suite against a throwaway DB (two non-obvious prerequisites)

If you spin up a fresh Postgres just to run `mix test` (e.g. an isolated audit/CI-repro container), two things bite in order:

1. **Postgres must be 18+.** The baseline `structure.sql` uses `uuidv7()` (PK default) and `SET transaction_timeout` — both PG17-and-earlier fail (`function uuidv7() does not exist` / `unrecognized configuration parameter`). Use `postgres:18-alpine`. This is the test-side mirror of the prod cutover in [[pg18-uuidv7-prod-crashloop-2026-06-11]].
2. **The `engram_app` role must exist before migrate.** The baseline dump ends with `GRANT ... TO engram_app`; with no role you get `role "engram_app" does not exist`. `mix engram.prepare_database` creates it (+ default privileges).

The `test` mix alias already chains this correctly:
`["ecto.create --quiet", "engram.prepare_database", "ecto.migrate --quiet", "test"]` — so **plain `mix test` against a fresh PG18 DB just works**. The trap is hand-rolling `mix do ecto.create, ecto.migrate, test`, which skips `prepare_database` and dies on the GRANT. Point a throwaway DB at it with `DATABASE_URL=postgres://engram:engram@host:port/engram_test mix test` (config/test.exs honors `DATABASE_URL`).

## RLS Testing (Critical)

Every test must verify tenant isolation:
- Query as User A with User B's tenant context → must return zero rows
- Insert as User A, attempt read as User B → must fail
- `FORCE ROW LEVEL SECURITY` means even the table owner can't bypass policies

See `docs/context/database-schema-rls.md` for the RLS spike test example.

## CI Pipeline

All tests run in GitHub Actions (`.github/workflows/ci.yml`):

1. **Unit tests** — `mix test` + `python3 -m pytest e2e/unit_tests/ -v` (E2E helpers)
2. **E2E tests** — starts CI stack + headless Obsidian, runs full sync scenarios

**Code quality checks:** `mix format --check-formatted` and `mix credo`. Dialyzer optional (slow, add later).

## References
- ExUnit tests: `test/`
- E2E tests: `e2e/tests/`
- CI config: `.github/workflows/ci.yml`
