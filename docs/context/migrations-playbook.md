# Context Doc: Migrations Playbook

_Moved from AGENTS.md on 2026-10-28._ AGENTS.md keeps the short form of these rules
("Database changes"); this is the long form.

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

## Background queries bound rows READ, not rows returned

Every background sweep, backfill and data-migration query must bound the rows
each statement READS. `WHERE <rare predicate> AND id > $after ORDER BY id
LIMIT N` bounds rows RETURNED: once matches are rare (the steady state of any
backfill that works) Postgres walks most of the table to fill the LIMIT, and a
fleet-wide `SELECT EXISTS(<rare predicate>)` "anything left?" check walks it
again. Both grow with the table and with how DONE the job is, and both hit the
15 s query timeout in prod (#2276, `note_index_state`).

- Walk fixed id windows with `Engram.Backfill.IdWindows`: the next N keys by
  keyset alone, the predicate applied only inside that window, the cursor
  advanced by the window's last key. Fleet-wide on the maintenance pool or per
  user, chosen for you by `reduce_all/4`.
- Completion is "a walk over every window found nothing"
  (`IdWindows.heal_pass/4`, `DataMigrations.any_row?/1`), never a separate
  EXISTS over the table.
- A predicate an index serves (a partial index whose WHERE the query implies)
  may page directly; prove it with `Engram.QueryPlan`.
- Never `timeout: :infinity`, and do not raise the timeout to make a sweep
  fit: the pool's default is the guard (15 s on `Engram.Repo`,
  `Engram.RuntimeConfig.maintenance_timeout/0` on the maintenance pool). A
  window statement should take milliseconds; one near either limit is a
  window too large or a predicate outside the window. A deliberate daily
  full aggregate (a report) passes `maintenance_timeout/0` explicitly, so
  self-host, where the maintenance pool is `Engram.Repo`, gets it too.
- Test it: `Engram.QueryRecorder.unwindowed/4` lists any statement that reads
  a table outside a window.

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
