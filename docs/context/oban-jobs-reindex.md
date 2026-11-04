# oban_jobs reindex: one-off runbook and the daily Reindexer

_Last verified: 2026-11-03 (prod read-only, Postgres 18.3, Oban 2.24.2)_

## Why

`oban_jobs` is a queue: every row is inserted, updated a few times and pruned
within 24 h. VACUUM frees index entries but never shrinks a btree or GIN, so
the indexes grow past the live data. Prod on 2026-11-03: 150 MB total, heap
76 MB for 17 MB of live rows (44,894), indexes 73 MB (`oban_jobs_args_index`
36 MB, `..._state_queue_priority_scheduled_at_id_index` 19 MB, pkey 7.5 MB).

`Oban.Reindexer` (`Engram.Jobs.reindexer/0`) now rebuilds every index daily at 10:37
UTC as `engram_app`, which holds MAINTAIN on the table (migration
20261103200000). This runbook is the ONE manual catch-up before the first
daily run, and the cleanup if a run fails.

Heap bloat is left alone: `VACUUM FULL` takes ACCESS EXCLUSIVE (stops every
Oban insert and fetch), pg_repack is not installed, and the free space inside
the file is reused by later inserts.

## Who runs it

A human, or an agent with Todd's explicit go for this run (it is a prod
change). Role `engram_admin` (table owner, RDS master). Password from SOPS
`rds_master_password` (engram-infra `secrets/prod.enc.yaml`,
`sops-operator-guide.md`), loaded into `PGPASSWORD` only. Never echo, print or
log it.

## Window

Weekday **19:20 UTC**: insert rate at its daily low (~700/h). Avoid
10:00-11:15 UTC (daily heavy window), 00:00-04:59 (imports and the 04:xx
cluster), 16:00 (insert peak), and the minutes :10 (CrdtBloatSweep) and :17
(BookkeepingCanary). No deploy in progress.

## Cost and locks

`REINDEX TABLE CONCURRENTLY` builds each index anew, then swaps it in. It
takes SHARE UPDATE EXCLUSIVE: reads, inserts, updates and deletes continue. It
blocks autovacuum, ANALYZE and DDL on `oban_jobs` while it runs; each swap
takes a brief stronger lock. Each build waits for every transaction older than
it, so a long transaction stretches it. Transient disk about the index size
(73 MB) plus WAL. Estimated 1-3 min (not measured). Cannot run in a
transaction block.

## Steps

```bash
# 1. Bastion + port-forward as in engram-infra docs/context/prod-db-readonly-access.md,
#    local port 15432. Record the port-forward PID; kill THAT PID afterwards (never pkill -f).
# 2. Connect as engram_admin, sslmode=require, password from SOPS into PGPASSWORD only.
```

```sql
-- Pre-checks (all must pass)
SELECT pg_size_pretty(pg_total_relation_size('oban_jobs')) AS total,
       pg_size_pretty(pg_indexes_size('oban_jobs'))        AS idx;      -- baseline
SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
 WHERE x.indrelid = 'oban_jobs'::regclass AND NOT x.indisvalid;       -- expect 0 rows
SELECT pid, usename, now() - xact_start AS age, left(query, 80)
  FROM pg_stat_activity WHERE xact_start < now() - interval '1 minute'; -- expect none; else wait
SELECT pid, query FROM pg_stat_activity
 WHERE query ILIKE '%reindex%' AND pid <> pg_backend_pid();            -- nobody else reindexing
-- CloudWatch FreeStorageSpace > 2 GB

-- Run
SET statement_timeout = 0;
SET lock_timeout = '10s';            -- give up rather than queue behind DDL
SET maintenance_work_mem = '256MB';  -- this session only
REINDEX (VERBOSE) TABLE CONCURRENTLY oban_jobs;

-- Post-checks
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid))
  FROM pg_stat_user_indexes WHERE relname = 'oban_jobs' ORDER BY 1;
SELECT pg_size_pretty(pg_indexes_size('oban_jobs'));                    -- expect roughly 10-20 MB
SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
 WHERE x.indrelid = 'oban_jobs'::regclass AND NOT x.indisvalid;       -- expect 0 rows
```

Afterwards: stop the bastion, kill the port-forward PID, write the before and
after sizes into the vault note `50 Engineering/Oban Jobs Table Slimming 2026-11-03`.

**Confirm the cadence.** For a week after the one-off REINDEX, record the
oban_jobs index sizes once a day, after the 10:37 UTC Reindexer run (read-only
as `engram_audit_ro`; the post-check query above). Daily sizes that stay
roughly flat mean daily is enough; growth between runs means it is not.

## If a run fails midway (manual or the daily Reindexer)

A cancelled or timed-out concurrent build leaves an invalid copy named
`<index>_ccnew` (or `_ccold` if it failed after the swap). Postgres still
maintains it on every write, so it is pure cost. The Reindexer tries to drop
invalid `oban_jobs*` indexes on its next run, but `DROP INDEX` needs the
OWNER: as `engram_app` that drop fails (logged as an Oban plugin error) and
the copy stays. The likely cause is the session's 10 s `lock_timeout`: a
concurrent build waits for older transactions, and that wait counts.

Find and drop them as `engram_admin`, one statement each, never an index
without the suffix:

```sql
SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
 WHERE x.indrelid = 'oban_jobs'::regclass AND NOT x.indisvalid;
DROP INDEX CONCURRENTLY public.<name>_ccnew;
```

`mix engram.index_audit` also lists index validity.
