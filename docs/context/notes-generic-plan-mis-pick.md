# Keyed `notes` lookups run unnamed: the generic-plan mis-pick

_Last verified: 2026-11-12_

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

## Rules

- A keyed `notes` lookup stays unnamed. To name one, first add a
  generic-plan test at the 40-tenant shape that asserts EVERY scan reads its
  key index, and run it under `engram_app` with seq scans on.
- To cut planning cost, send fewer parts or touch fewer indexes; do not cache
  the plan.
- The bigger lever is the index count on `notes` (planning tracks indexes x
  parts). Dropping the HMAC index set after `note_split` is a schema change
  and needs Todd.
