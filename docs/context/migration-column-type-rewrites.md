# Context Doc: Widening a column type without rewriting the table

_Last verified: 2026-07-30_

## Status

Working. Measured on PostgreSQL 18.4 (the version in `backend-postgres-1` and prod RDS).

## What This Is

`ALTER TABLE ... ALTER COLUMN ... TYPE ...` sometimes rewrites the entire heap
under `ACCESS EXCLUSIVE` and sometimes costs nothing. The difference is not
obvious from the SQL, squawk's `changing-column-type` rule cannot tell them
apart, and **the intuitive answer is wrong for array columns**.

Read this before writing a widening migration or before dismissing squawk's
`changing-column-type` warning as a false positive.

## The rule, and the trap

PostgreSQL skips the rewrite when the old type is **binary coercible** to the
new one and the `USING` clause does not change contents. `varchar(n)` → `text`
qualifies: it only drops a length constraint.

**That does not extend to the array form.** `varchar(n)[]` → `text[]` rewrites
the whole table, even though the element cast is coercible. The no-rewrite
optimisation is not applied at the array level.

| Change | Rewrite? |
|---|---|
| `varchar(n)` → `text` | No |
| `varchar(n)` → `varchar(m)`, m > n | No |
| `varchar(n)[]` → `text[]` | **Yes, full rewrite** |
| `text` → `varchar(n)` (narrowing) | Yes (must verify every row) |

## How to measure it yourself, rather than guess

`pg_class.relfilenode` is the on-disk file. If it changes, the heap was
rewritten. This is the whole test:

```sql
CREATE TABLE probe (id int, col varchar(255));
INSERT INTO probe SELECT g, repeat('x',200) FROM generate_series(1,20000) g;
SELECT relfilenode FROM pg_class WHERE relname='probe';   -- before
ALTER TABLE probe ALTER COLUMN col TYPE text;
SELECT relfilenode FROM pg_class WHERE relname='probe';   -- after; same = no rewrite
```

Run it against a real container, not a mental model:

```bash
docker exec -i backend-postgres-1 psql -U engram -d postgres -At -v ON_ERROR_STOP=1 <<'SQL'
...
SQL
```

Observed 2026-07-30: scalar `82860 → 82860` (unchanged), array `82865 → 82870`
(changed).

## Array default has to be dropped and restored

An array column's `DEFAULT` is typed, so the type change fails while it is
attached. Order matters:

```elixir
execute "ALTER TABLE t ALTER COLUMN c DROP DEFAULT"
execute "ALTER TABLE t ALTER COLUMN c TYPE text[]"
execute "ALTER TABLE t ALTER COLUMN c SET DEFAULT ARRAY[]::text[]"
```

## squawk

`changing-column-type` is deliberately left enabled in `.squawk.toml` and fires
on **every** such ALTER, coercible or not. There is no per-statement ignore, so
the only escape is the file-level `# squawk-ignore-file` marker that
`priv/repo/lint_migrations.sh` greps for (documented in `AGENTS.md` alongside
`safety_assured:`).

Using it obliges you to have done the relfilenode measurement and to write the
result into the file. "squawk is generic, this is fine" is not a justification;
it is the assumption that needs testing.

Note this lint lives in the **`unit-tests`** CI job, after the test run. A job
that reports `N tests, 0 failures` can still fail here, so read to the end of
the log rather than stopping at the test summary.

## Gotchas

- **The lint is CI-only.** No local `mix` task runs squawk, so a widening
  migration passes every local gate and fails on push. Run the relfilenode probe
  locally instead.
- **"Binary coercible" is about the pair of types, not about the direction
  feeling safe.** Widening intuitively sounds free; for arrays it is not.
- **A rewrite is not automatically a blocker.** On a small table it is
  milliseconds. The judgement is `rewrite × row count`, so state the row count
  in the justification instead of claiming there is no rewrite.
- **Indexes on the column are rebuilt** even in the no-rewrite case, which is
  another reason to check size rather than assume free.

## Failed Approaches / Dead Ends

- **Asserting no-rewrite from the docs alone.** The "binary coercible" wording
  reads as though it covers `varchar[]` → `text[]`. It does not. This shipped a
  false `safety_assured:` claim in PR #1147 that squawk caught.
- **Treating a squawk `changing-column-type` hit as noise.** It was right; the
  justification was wrong.

## References

- Migration: `priv/repo/migrations/20260730180000_widen_oauth_text_columns_expand.exs`
- `AGENTS.md` → "The `# safety_assured:` escape"
- `priv/repo/lint_migrations.sh`, `.squawk.toml`
- PR #1147 (Windsurf `state` overflow, which prompted the widening)
