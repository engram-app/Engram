# Context Doc: Testing Strategy

_Last verified: 2026-10-03_

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
| **E2E harness unit tests** | `e2e/unit/` | `cd e2e/unit && python3 -m pytest -v` | Harness helpers (cleanup SQL safety, timeout budgets, probes) | None |
| **Headless protocol** | `e2e/headless/` | `headless-protocol` CI job | Real plugin SyncEngine vs real backend over WS, no Obsidian | Backend stack |
| **Plugin sim tier** | plugin repo `tests/sim/` | `bun test tests/sim/` (plugin) | Seeded deterministic CRDT convergence | None |

## Elixir Testing Stack

| Tool | Purpose |
|------|---------|
| **ExUnit** | Test framework |
| **Ecto.Adapters.SQL.Sandbox** | Per-test DB transactions (auto-rollback) |
| **ExMachina** | Test data factories |
| **Mox** | Behaviour-based mocks (embedder, Qdrant client) |
| **Bypass** | HTTP mock server (for Voyage AI, Qdrant API) |

Key advantage: `async: true` runs tests in parallel with per-test DB transactions. No cleanup needed.

## Running locally

See `docs/context/local-backend-testing.md` (`scripts/test-local.sh`). A fresh
DB needs Postgres 18+ (`uuidv7()`); plain `mix test` runs
`engram.prepare_database` via the `test` alias. Hand-rolling
`mix do ecto.create, ecto.migrate, test` skips it and dies on the baseline's
`GRANT ... TO engram_app`.

## RLS Testing

Naive isolation tests prove nothing: the suite connects as a superuser, which
bypasses RLS. See `docs/context/rls-enforcement-testing-traps.md` before
writing a tenant-scoping test.

## CI Pipeline

All tests run in GitHub Actions (`.github/workflows/verify.yml`):

1. **Unit tests**, `mix test`. The stack-free `e2e/unit` harness tests run as a step of the `e2e-clerk` job
2. **E2E tests**, CI stack + headless Obsidian, full sync scenarios. Report-only on PRs; see `docs/context/testing-architecture-migration.md` and `docs/context/ci-pipeline-gating.md`

**Code quality checks:** `mix format --check-formatted` and `mix credo --strict` (both fatal in the `lint` job). Dialyzer is not in CI; run it locally before pushing. See AGENTS.md "Quality Tooling" for the full fatal-lint set.

## References
- ExUnit tests: `test/`
- E2E tests: `e2e/tests/`
- CI config: `.github/workflows/verify.yml`
