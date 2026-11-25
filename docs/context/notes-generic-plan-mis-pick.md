# Keyed `notes` lookups run unnamed: the generic-plan mis-pick

_Last verified: 2026-11-16_

## What this is

Postgrex prepares a NAMED statement per query shape and reuses it on its
connection. From the 6th execution Postgres may switch a named statement to
a GENERIC plan: built once without parameter values, then reused if its
estimated cost beats the average custom plan. A generic plan is costed for an
average vault, not the one asked for. For a lookup by key on `notes`, that
estimate picks the wrong index.

`Engram.Notes.Keys.lookup?/1` + `Repo.prepare_query/3` (`custom_plan/2`) run
every keyed `notes` lookup with `prepare: :unnamed`, so each call gets a
custom plan. `Keyword.put_new` means a caller's explicit `prepare:` wins.
Do not use that opt-out without a generic-plan test at the shape below.

## The incident (2026-11-02)

Prod, `engram_app` with RLS: the path lookup's generic plan read
`notes_recent_index (user_id, vault_id, ...)` and filtered `path_id` row by
row over a 40k-note vault (12,665 buffers a call, 130k calls in 5 days). Its
custom plan read `notes_path_live` (3 buffers).

Why: a generic `vault_id = $2` is costed as an average vault, a few rows, so
every vault-led index ties with the key index at about one page, and index
order breaks the tie. `= ANY($n)` is costed as 10 descents, which makes the
key index look MORE expensive than one descent of a vault-led index.

## Reproducing the prod plan in a test

```elixir
for table <- ~w(notes attachments), col <- ~w(user_id vault_id),
    do: Repo.query!("ALTER TABLE #{table} ALTER COLUMN #{col} SET (n_distinct = 40)")
QueryPlan.fresh!("notes")       # CLUSTER on pkey + ANALYZE: this test's rows only
QueryPlan.fresh!("attachments")
```

40 tenants make a generic `vault_id = $n` a fraction of the vault, as prod's
hundreds do. On the pre-fix code this setup reproduced the 11-02 plan
exactly. Then read the plan as prod runs it: inside `as_prod_role/1`, set
`app.current_tenant`, and call `QueryPlan.generic_plan(sql, seqscan: true)`
(seq scans on: the question is which plan Postgres PICKS). Pin custom plans
with `QueryPlan.after_runs(fun, pattern, no_generic: true)`
(`test/engram/notes_generic_plan_test.exs`).

## Second instance: the link-target union (plan A, 2026-11-12)

`Links.target_candidates/4` (behind `links_for_note/2`,
`backlinks_for_note/3` and the extract-links writer) is a `union_all` of
three parts per table (`stale`, `pathed`, `shortest`) for notes and
attachments. Planning it cost 3.75-8.11 ms a call (unpruned medians,
EXPLAIN ANALYZE as `engram_app`, local ~1,000-note vault) against 0.4-2.9
ms of execution, so we tried `prepare: :named` on it. (An earlier local
scale profile at 9 to 50,000 notes saw 4.7-20.5 ms of planning; that was
a different measurement, not repeated here.)

Result: it went generic after 5 calls (`pg_prepared_statements.generic_plans
> 0`), and with the setup above its generic plan read, per part:

| Part | Generic plan reads | Key index it should read |
|---|---|---|
| notes stale | `notes_user_vault_live` (user_id, vault_id), `basename_id = ANY($3)` only a row filter | `notes_link_keys_stale` |
| notes pathed | `notes_path_ci` | `notes_path_ci` |
| notes shortest (grouped min) | `notes_user_vault_live` | `notes_basename` |
| notes shortest (join back) | `notes_user_vault_live` | `notes_basename` |
| attachments stale | `attachments_link_keys_stale_index` | same |
| attachments pathed | `attachments_user_live_size` (user_id, vault_id) | `attachments_user_id_vault_id_path_ci_hmac_index` |
| attachments shortest x2 | `attachments_user_live_size` | `attachments_user_id_vault_id_basename_hmac_path_length_index` |

HMAC mode (before the `note_split` ledger is done): all four notes scans on
`notes_user_vault_live`. That is a whole-vault walk per call on a hub vault,
the 11-02 mis-pick again. So `:named` was dropped, and the union stays
unnamed. `test/engram/links/target_candidates_plan_test.exs` guards that it
has no `pg_prepared_statements` row.

What shipped instead: a part whose key list is empty is not sent (no
`pathed` part without a folder-qualified target, no `shortest` part without
a bare one). An `= ANY('{}')` part returns nothing but is still planned
against every index. Measured locally (EXPLAIN ANALYZE as `engram_app`,
~1,000-note vault, median of 25 alternating runs, 3 repeats): planning
dropped 25.2-29.8% on a bare-names call (6 -> 4 parts, 1.2-2.2 ms saved)
and 54.8-58.5% on a folder-qualified call (2.1-3.3 ms saved), with
identical rows. A call with both shapes still sends all six parts.
`target_candidates_equivalence_test.exs` pins the answers per call shape
(bare-only, qualified-only, mixed) and asserts each takes its pruned path.
Dropping `pathed` alone would not change answers (a qualified miss falls
back to fetching every same-named row), only cost; the plan test's SQL
assertions are what catch that.

## Third instance: the folder walk under RLS (Gap A, 2026-11-15)

`Rows.ids_by_path/3` walks a batch of folder paths down
`folders_live_name` (`WalkSql.walk_many/0`). Planned as `engram_app` at the
40-tenant shape (`n_distinct = 40` on `folders.user_id`/`vault_id`, 170
folders in one tenant), each probe read `folders_user` (the tenant's whole
folder index, filtered) instead of the unique name index, in the CUSTOM
plan too. Cause: the policy's tenant is an InitPlan, so the planner costs
`folders_user` at the average tenant's size (about 4 rows here) and ties it
with the 1-row unique probe; the smaller index wins the tie. Prod has many
tenants with a handful of folders and a few with thousands, so the average
is small and a heavy tenant pays a scan per probe.

Fix: each probe also says `f.user_id = $user` as a bound value, so the
custom plan sees this tenant's real count (most-common-value statistics),
and the statement runs unnamed (`prepare: :unnamed`), so no generic plan
replaces that estimate. After: 9 probes, 26 buffers, all
`folders_live_name` (`ChainReadsTest`). The single-path walk embedded in the
S3 name match (`WalkSql` `@walk`) has the same probe shape and was only
proven without folder stats overrides; it runs only in moved vaults (S5).

## Fourth instance: the walk read every sibling (staging 0.87.0, 2026-11-16)

The fix above held at the root but not below it. Staging row 7, as
`engram_app`: every probe under the root read `folders_live_parent_id`
(`Index Cond: (vault_id, parent_id)`, `name_hmac` a Filter), so a level
cost O(siblings). The SAME plan as the superuser, so not RLS and not a
leakproof problem. The cause is the cost model:

- the planner treats `vault_id` and `parent_id` as independent and
  multiplies their selectivities: 1,436 rows x 1/8 vaults x 1/412 parents
  = 0.43, clamped to 1 row. So the parent-keyed scan is estimated at the
  same one row and one heap page as the unique
  `(vault_id, parent_id, name_hmac)` probe. More vaults and parents only
  lower that estimate (the heap is NOT in parent order: correlation 0.033);
- the two tied at 8.30 vs 8.43, and the gap was only btree height:
  `folders_live_name` had churned to 615 pages for 1,406 entries (41k
  inserts, 50k deletes), one level taller than the 32-page
  `folders_live_parent_id` rebuilt on 11-11. The startup costs show it:
  0.28 = height 1, 0.40 = height 2.

In a test with fresh indexes the tie went to `folders_parent` instead, at
the root too. Either way the actual sibling count never enters the plan.

Fix: `folders_live_name_ids`, the same key with `INCLUDE (user_id, id)`.
Every walk probe reads only those, so it is an index-only scan with no heap
page, about half the cost, which no plain scan of another index ties while
the table is mostly all-visible (staging 577 of 607 pages; right after a
CLUSTER, VACUUM FULL or restore the tie can return until autovacuum sets
the visibility map). Not unique:
`folders_live_name` stays the constraint. `Rows.live_child` (the
conflicted-insert read) now probes `id` alone, then reads the row by key
under the same live predicate (a row tombstoned in between is not returned).
`WalkIndexCondTest` reproduces it with `parent_id` n_distinct -0.29 and
`QueryPlan.all_visible!/1`, 500 vs 5 siblings: 9 buffers for 3 prefixes
either way.

Rule: when a probe must use ONE index and another index shares its leading
keys, a tie is decided by size and height, not siblings. Make the right
index strictly cheaper (index-only) rather than hoping the estimate
separates them.

## Rules

- Read every plan as `engram_app` with a tenant (`QueryPlan.rls_plans/3`). As
  the suite's superuser RLS is skipped and a qual it would bar from an index
  looks fine (rls-leakproof-index-quals.md, the S3 lookup 2026-11-13).

- A probe whose only tenant qual is the RLS policy's is costed at the
  AVERAGE tenant. When a tenant-only index can tie with the key index, add
  the tenant as a bound value and send the statement unnamed.
- A keyed `notes` lookup stays unnamed. To name one, first add a
  generic-plan test at the 40-tenant shape that asserts EVERY scan reads its
  key index, and run it under `engram_app` with seq scans on.
- To cut planning cost, send fewer parts or touch fewer indexes; do not cache
  the plan.
- The bigger lever is the index count on `notes` (planning tracks indexes x
  parts). Dropping the HMAC index set after `note_split` is a schema change
  and needs Todd.

## Fifth instance: the folder walk picks a parent-only index on an unvacuumed table (2026-11-17)

- The 0.87.0 fix (PR 2616) added `folders_live_name_ids` and won the planner
  tie only via an Index Only Scan. Its test (`WalkIndexCondTest`) marked pages
  all-visible, so it hid the problem.
- Right after a deploy the `folders` table is not all-visible. The planner
  estimates ~1 row for any `(vault_id, parent_id)` lookup, so every index with
  that prefix ties. It picked `folders_parent` (the FK index), later the new
  `folders_parent_all_ids` (PR 2609), with `name_hmac` only as a Filter (the
  failing unit test on main: 84 rows discarded per level at 500 siblings).
  Staging: 48 vs 27 buffers at depth 9.
- Fix (PR 2635): one index `folders_parent_name_ids` `(vault_id, parent_id,
  name_hmac, id) INCLUDE (user_id, deleted_at)`, built CONCURRENTLY, then
  `folders_parent` and `folders_parent_all_ids` dropped in a later migration.
  The FK `(vault_id, parent_id)` is composite, so the new prefix serves the RI
  check (pinned by a `pg_constraint` test).
- Rule: plan tests for keyed lookups must also run on a NOT all-visible table
  (no VACUUM, no all-visible setup), as `engram_app`, custom + generic. Any
  index sharing a keyed lookup's leading columns must also carry the key
  column, or it ties.
