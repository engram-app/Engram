# Under RLS, a non-leakproof qual cannot drive an index

_Last verified: 2026-11-13_

## What this is

Every tenant table runs FORCE ROW LEVEL SECURITY, and prod queries run as
`engram_app` with `app.current_tenant` set. Postgres must not let a
user-written qual see a row before the policy has passed it, because a
function could leak the row's values (in an error message, say). So it
evaluates a qual **ahead of** the policy's quals only if the qual is
*leakproof*. A qual that is not leakproof waits until the policy has
filtered the rows. That rules it out as an index condition, which runs
before any filter.

The test is per function, and only for functions applied to a COLUMN (in
PG terms, a Var). Equality on plain types is leakproof: `byteaeq`,
`uuid_eq`, `texteq` and `int8eq` all read `proleakproof = t` here, and
`IS NULL` and `NOT` are not function calls at all. Many other functions are
not leakproof, including `byteacat` (the `||` operator on `bytea`) and
`uuid_send`, both `proleakproof = f` on PG 18.4.

Check one with `SELECT proname, proleakproof FROM pg_proc WHERE proname = '...'`.

What stays usable:

- a plain column compared to a bound value (`path_id = $1`);
- a column compared to the result of an uncorrelated subquery. That
  becomes an InitPlan parameter, a Param, which is safe;
- a non-leakproof function applied only to Params or constants, in the
  select list or on the right-hand side;
- an `OR`, if every arm is leakproof. One leaky arm makes the whole `OR`
  leaky.

An expression index (`ON notes ((a || b))`) is usable only by a query that
names the same expression, so under RLS it is unusable whenever the
expression contains a non-leakproof function. The fix is a stored column,
kept by a trigger, indexed plainly.

## The incident (S3, staging 2026-11-13)

The S3 by-path lookup (Engram#2587) was
`path_id = $1 OR (name_ci_hmac || uuid_send(folder_ref_id)) = (...)`,
backed by the expression index `notes_folder_name_live`. As a superuser it
planned a BitmapOr of `notes_path_live` and `notes_folder_name_live` (6
buffers). As `engram_app`, the `OR` was leaky as a whole, so neither arm
could drive an index. The lookup read the tenant's whole vault on
`notes_user_vault_live`: 1,341 buffers on a 1,530-note vault, against 4 on
0.83.0. This happened in custom, generic and auto plan modes. get_notes'
median went from 21 ms to 37-45 ms.

The fix (fix/s3-rls-lookup-plan):

- `notes.name_key` is a stored column, kept by the `notes_set_name_key`
  trigger and indexed by `notes_name_key_live`.
- The name arm became `id = (CASE WHEN <moved> THEN (SELECT ... WHERE
  name_key = (<walk> SELECT $ci || uuid_send(w.id)) ...) END)`. Every qual
  compares a plain column to a Param.
- The folder chain read (`Rows.chain_rows/3`) was a recursive CTE whose
  step the planner hash-joined over the vault's folders. It now walks a
  LATERAL `LIMIT 1` primary-key probe per row.

## Why the plan tests missed it

The suite connects as a superuser, and a superuser bypasses RLS. A plan
read with `QueryPlan.generic_plan/2` or a bare `EXPLAIN` outside
`Repo.with_tenant` therefore shows the index the qual WOULD drive if the
policy did not exist. `LocationPlanTest` asserted `notes_folder_name_live`
and passed.

## Testing a plan as prod runs it

Use `QueryPlan.rls_plans(user_id, sql, params)`, which:

- runs `SET LOCAL SESSION AUTHORIZATION engram_app` (not `SET ROLE`:
  `Repo.with_tenant` resets the role, see rls-enforcement-testing-traps.md)
  and sets the tenant;
- runs `DISCARD PLANS` and turns `enable_seqscan` off. A test table is
  tiny, so a Seq Scan that is still in the plan means no index can serve
  it;
- returns `custom`: `EXPLAIN (ANALYZE, BUFFERS)` with the recorded values;
- returns `generic`: `PREPARE` under `plan_cache_mode =
  force_generic_plan`, then `EXPLAIN (ANALYZE, BUFFERS) EXECUTE` with the
  same values. They are inlined as typed literals, because EXECUTE takes
  no protocol parameters.

Record the real call's statements with `QueryRecorder.record/1`, then plan
each one. `test/engram/notes/location_rls_plan_test.exs` is the model:

- it runs the call 7 times on one connection;
- it asserts every custom plan;
- it asserts the generic plan only of statements Postgrex prepared NAMED,
  which are the only ones that can go generic (check
  `pg_prepared_statements`);
- it seeds about 1,000 notes and 120 sibling folders, and ANALYZEs.
  Without fresh statistics, a probe by parent ties with a probe by name on
  a tiny table and the plan flips (`LocationPlanTest` did, until it
  analyzed).

`QueryPlan.buffers/1` reads the top node's buffer count.

Notes:

- A keyed `notes` lookup's generic plan reads the vault even on 0.83.0
  (81 buffers per 1,000 notes for the path lookup). That is why such
  lookups run unnamed (`Keys.lookup?/1`, notes-generic-plan-mis-pick.md).
  Assert that they stay unnamed rather than asserting their generic plan.
  `Keys.lookup?/1` now also sees a key inside a FROM or JOIN subquery
  (get_notes' budget cut).
- Pre-existing and not fixed here: under a forced generic plan,
  `get_note_by_id`'s fetch by `id` and the folder lookup by
  `full_path_hmac = ANY` read the vault's notes and folders. Both run
  NAMED. Whether prod's planner switches them is not measured.

## Rules

- Never put a non-leakproof function on a column in a predicate of a
  tenant-table query. Compute the value in Elixir, or store it in a
  column kept by a trigger, then compare that plain column.
- Every plan assertion on a tenant table runs as `engram_app` with a
  tenant (`QueryPlan.rls_plans/3`). A superuser plan proves nothing about
  index use.
