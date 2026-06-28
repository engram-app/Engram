# Running the backend ExUnit suite locally

Fast local `mix test` against a docker Postgres — no CI round-trip. The
`scripts/test-local.sh` wrapper encodes everything below; reach for the doc only
when the script misbehaves or you want to understand the moving parts.

## TL;DR

```bash
scripts/test-local.sh                         # whole suite (~190s, 3200+ tests)
scripts/test-local.sh test/engram/foo_test.exs[:42]   # one file / line
scripts/test-local.sh --teardown              # drop the test DB after
scripts/test-local.sh --reset -- test/...     # drop+recreate test DB first
```

Runs from the main checkout OR any worktree (it resolves its own repo dir).

## What it needs

- **Elixir/OTP locally** — `elixir --version` (1.19 / OTP 26 works; project targets 1.17+).
- **Postgres on `localhost:5432`, creds `engram/engram`** — these are the
  defaults baked into `config/test.exs` (used only when `DATABASE_URL` is
  unset). The `backend-postgres-1` docker container already serves this; start
  it with `docker start backend-postgres-1` if it's down. Container is shared
  with dev — the script never stops it, only drops the `engram_test` DB.
- **Nothing else.** The `test` mix alias self-bootstraps the schema:
  `ecto.create --quiet` → `engram.prepare_database` → `ecto.migrate --quiet` →
  `test`. `engram.prepare_database` is the cluster bootstrap (creates the
  `engram_app` role + DEFAULT PRIVILEGES) that the baseline dump's GRANTs need —
  skip it and migrations fail. It's idempotent.

## The three gotchas the wrapper handles

1. **Worktree dep-lock mismatch.** New worktrees hardlink `deps/` from the
   parent checkout (see the `post-checkout` hook), so they carry the *parent
   branch's* `mix.lock`. `MIX_ENV=test mix compile` then dies with
   `lock mismatch ... run "mix deps.get"`. A `mix deps.get` reconciles to the
   current tree's lock (no-op when already in sync). The script always runs it.
2. **Stray `DATABASE_URL`.** `config/test.exs` reads `DATABASE_URL` first; if
   your shell exports one (e.g. from a dev `.env`), the suite silently runs
   against the wrong DB. The script `unset`s it.
3. **Postgres not up.** mix's connect error is noisy; the script pre-checks the
   TCP port and prints the `docker start` hint instead.

## Teardown

Per-test data is reverted by the Ecto SQL sandbox automatically — no teardown
needed between runs. `--teardown` only drops the `engram_test` *database* so you
leave zero schema behind; the next run recreates it. `--reset` does the same up
front when you suspect a stale/partial schema.

## Notes

- Excluded tags (need external infra): `:qdrant_integration`, `:cluster`,
  `:integration` — the local run skips them, matching CI's unit-tests job.
- CI uses an ephemeral postgres + a shared `_build` cache; locally you reuse the
  same `backend-postgres-1` and your worktree's `_build`. Same `mix test`,
  same alias, so green locally == green in the `unit-tests` job.
- Sandbox + `:global` CrdtDoc rooms: tests that exercise the CRDT path spin
  global rooms that outlive the test; `test/support/data_case.ex` stops them in
  `on_exit` before the sandbox owner is torn down (see #777). If you add CRDT
  tests, keep them `async: false`.
