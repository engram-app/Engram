# AGENTS.md — guidance for AI coding assistants

This file tells AI agents (Claude, Copilot, Cursor) and humans how to work
on this codebase without tripping CI gates. The gates themselves enforce
correctness; this doc shortens the iteration loop.

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

## Self-host story

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

## Where to find things

- Squawk config: `.squawk.toml`
- Lint runner: `priv/repo/lint_migrations.sh`
- New-migration discovery: `priv/repo/list_new_migrations.sh`
- AST extractor: `lib/mix/tasks/engram.migration_drops.ex`
- CI jobs: `.github/workflows/verify.yml` — `phase-label-required`, `contract-phase-references`, `migrations-immutable`, `Lint new migrations (squawk)`, `Test new migrations roll back (ecto.rollback)`
