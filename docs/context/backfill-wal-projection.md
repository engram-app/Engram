# Context Doc: Projecting a backfill's prod WAL from staging (full-page images and density)

_Last verified: 2026-11-14_

## Status
Working. Measured on staging 2026-11-14 for the Gap B `note_links.qualified` backfill (`Engram.Workers.BackfillNoteLinkQualified`, PR 2592). The prod figures below are projections, not measurements.

## What This Is
How to size a `DataMigration` backfill's WAL and disk cost for prod from a staging run, and why a naive staging rows/min measurement undercounts badly.

## The core trap: full-page images (FPI)
After every checkpoint, the first change to any page (heap or index leaf) writes the whole 8 KB page into WAL. Later changes to the same page before the next checkpoint are cheap. So WAL per row depends on how many distinct pages each checkpoint interval touches per row:

- Staging has a small table. At the default pace one 5-min checkpoint covers ~25% of it, so many rows share each dirtied page and FPI per row is low.
- Prod has a big table. The same rows/min covers a tiny slice per checkpoint, so nearly every row dirties fresh pages.

Match **density** (share of the table touched per checkpoint interval), not rows/min.

## Measured (staging, Gap B)

| Run | Pace | Rows per checkpoint | WAL/row | FPI/row | WAL records/row | HOT updates |
|-----|------|---------------------|---------|---------|-----------------|-------------|
| 1 | default, 60k rows | ~25% of table | 2.2 KB | 0.20 | ~10 | 0 |
| 2 | slowed | ~1,200 (2%) | ~3.4 KB | 0.45 | | 0 |

Linear fit: **WAL/row ~= 1,240 B + 4.8 KB x FPI/row**.

### Why 0 HOT updates
`note_links` has a partial index whose predicate references the column being updated (`WHERE qualified ...`). Any update to an indexed or predicate column makes the update non-HOT, so every row inserts a new entry into all 10 `note_links` indexes (hence ~10 WAL records/row). Building such a partial index AFTER the backfill instead of before would let the backfill updates go HOT and cut WAL sharply.

## Method: sample WAL counters around the deploy

Prove a single consumer first (see Gotchas). Then run this every 60 s from ~10 min before the deploy until the ledger row completes, and subtract the pre-deploy baseline. Staging psql user is `engram`, db `engram` (container `engram-saas-postgres` on FastRaid).

```sql
SELECT now() AS ts,
       pg_current_wal_lsn() AS lsn,
       w.wal_bytes, w.wal_fpi, w.wal_records,
       (SELECT count(*) FROM note_links WHERE qualified IS NULL) AS null_rows,
       s.n_tup_upd, s.n_tup_hot_upd, s.n_dead_tup,
       pg_relation_size('note_links') AS heap_bytes,
       pg_indexes_size('note_links') AS index_bytes,
       (SELECT completed_at FROM data_migrations WHERE name = 'note_link_qualified' AND version = 1) AS ledger_done,
       (SELECT num_timed + num_requested FROM pg_stat_checkpointer) AS ckpts
FROM pg_stat_wal w, pg_stat_user_tables s
WHERE s.relname = 'note_links';
```

Loop it with a shell `while true; ... psql -AtF, -f sample.sql >> samples.csv; sleep 60; done`, stopping when `ledger_done` is set. Divide deltas of `wal_bytes`, `wal_fpi`, `wal_records` by rows backfilled (delta of `null_rows`), and count checkpoints from `ckpts`.

## Method: density simulation (no backfill needed)

Predicts FPI/row for any density from the staging data. Validated against both runs within 0.02 FPI/row.

Read-only on table data, but it creates a TEMP table, so run it on the primary (staging), not a replica.

It models 8 of the 10 `note_links` indexes: the `target_attachment_id` and `qualified` partial indexes are omitted (both ~5 pages, so they barely move the result).

1. Number rows in the backfill's walk order (PK).
2. Map each row to a pseudo leaf page per index: rank in that index's key order x (index pages / rows).
3. Map each row to its heap page via `ctid`.
4. For windows of R consecutive rows, count distinct pages. FPI/row = distinct pages / R.

Pick R = rows per checkpoint interval at prod density:
**R = (prod rows per checkpoint / prod table rows) x staging rows.**

Density matching is scale-invariant for both clustered indexes and random (HMAC-keyed) indexes, so the staging result transfers.

Set `N` to the staging row count (`select count(*) from note_links`). Keep the comment off the `\set` line: psql takes everything after the name as the value, so a trailing `-- comment` ends up inside `:N`.

```sql
-- N = staging row count
\set N 60179
create temp table r as
select row_number() over (order by id) as wi,
 (ctid::text::point)[0]::bigint as hp,
 floor((row_number() over (order by id)-1)*763.0/:N) as pk,
 floor((row_number() over (order by user_id,vault_id,target_key_hmac,id)-1)*689.0/:N) as tk,
 floor((row_number() over (order by source_note_id,position)-1)*981.0/:N) as sp,
 floor((row_number() over (order by user_id,vault_id,source_note_id,id)-1)*658.0/:N) as us,
 floor((row_number() over (order by vault_id,id)-1)*262.0/:N) as v,
 floor((row_number() over (order by user_id,vault_id,target_basename_hmac,id)-1)*736.0/:N) as bn,
 floor((row_number() over (order by user_id,vault_id,target_basename_hmac,id)-1)*74.0/:N) as st,
 case when target_note_id is not null then floor((row_number() over (partition by target_note_id is null order by target_note_id,id)-1)*151.0/(select count(target_note_id) from note_links)) end as tn
from note_links;
select R, round(avg(heap)::numeric/R,3) heap, round(avg(idx)::numeric/R,3) idx, round(avg(heap+idx)::numeric/R,3) fpi_per_row,
 round(avg(rnd)::numeric/R,3) hmac_keyed_per_row
from (values (474),(1200),(15000)) v(R),
lateral (select (wi-1)/R w, count(distinct hp) heap,
   count(distinct pk)+count(distinct tk)+count(distinct sp)+count(distinct us)+count(distinct v)+count(distinct bn)+count(distinct st)+count(distinct tn) idx,
   count(distinct tk)+count(distinct bn) rnd
   from r group by 1 having count(*)=R) x
group by R order by R;
```

The literal page counts (763, 689, ...) are each index's leaf pages on staging; get them from `pg_relation_size(index)/8192` and adapt the `order by` lists to the target table's index keys.

Results: R=474 gives 0.64 FPI/row, R=1,200 gives 0.465, R=15,000 gives 0.195.

## Pacing (`Engram.Backfill.PacedChain`)
- A hop runs up to `max_rows` (checked per 200-id window, so the effective minimum is 200 rows per hop) or 30 s, at `writes_per_s`. The 250 ms pause between windows is a minimum wait folded into the throttle wait (`Throttle.wait_ms/5` sleeps `max(pause, deficit)`), not added on top. The next hop is scheduled 45 s out (Gap B values in `backfill_note_link_qualified.ex`).
- Default 3,000 rows at 150/s gives ~2,770 rows/min.
- **A `max_rows` below 200 does nothing.** Throttle with `writes_per_s`.
- Hop formula: **rows/hop = min(max_rows, writes_per_s x 30 s, rounded up to a 200-id window)**; **cycle = hop time + 45 s** (`schedule_in`) + queue latency. At a low `writes_per_s` the 30 s budget, not `max_rows`, ends the hop.

## Prod disk: rate, not total
- RDS retains a bounded amount of WAL: `TransactionLogsDiskUsage` stayed flat at 2.35-2.55 GB while prod generated 0.8-1.2 GB/h of WAL. Generated WAL is archived and recycled, not held.
- So the gate is **GB/h plus `FreeStorageSpace`**, not total WAL over the run.
- CloudWatch metrics (Grafana datasource `grafanacloud-cloudwatch`): `TransactionLogsGeneration`, `TransactionLogsDiskUsage`, `FreeStorageSpace`.

## Projection for Gap B
- ~4.4 KB/row at ~1.9M prod rows (row count is an estimate, not measured).
- Default pace: 0.72 GB/h. If prod is half as clustered as staging: 1.24 GB/h.
- Recommended: `writes_per_s=50`. A hop stops at the 30 s budget (checked per 200-id window), so ~1,500-1,800 rows per hop and a ~81 s cycle (30 s + 45 s + queue latency): **~80k rows/h**, ~24 h for 1.9M rows.
  - Density: ~0.35% of prod rows per checkpoint, i.e. staging R ~212. FPI/row ~0.75 there, **extrapolated** past the lowest measured point (R=474, 0.64); not simulated or measured at R=212.
  - So ~4.85 KB/row (1,240 B + 4.8 KB x 0.75), **~0.39 GB/h modeled, ~0.67 GB/h pessimistic** (2x FPI).

## Failed Approaches / Dead Ends
- Measuring WAL/row on staging at the default pace and multiplying by prod rows: 2.2 KB/row understates prod by ~2x because staging shares FPIs across a dense checkpoint window.
- Lowering `max_rows` below 200 to slow the backfill: ignored by the 200-id window check.

## Gotchas
- **Prove a single consumer before any staging measurement:** `docker ps` on FastRaid, map each `pg_stat_activity.client_addr` to a container, and check `oban_peers`. A foreign app container on the staging DB will run (or fake) the backfill and pollute the WAL deltas.
- `pg_stat_wal` is cluster-wide: any other write traffic during the window lands in the delta. Take a baseline slope before the deploy and subtract it.
- Checkpoint timing matters: count checkpoints during the run (`pg_stat_checkpointer`) to compute rows per checkpoint interval.

## References
- `lib/engram/backfill/paced_chain.ex`, `lib/engram/workers/backfill_note_link_qualified.ex`
- `docs/context/data-migrations-ledger.md` (ledger mechanics)
- Engram PR 2592
