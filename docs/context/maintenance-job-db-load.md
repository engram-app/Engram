# Context Doc: Maintenance-job DB load (RDS swap alerts, O(table) cron scans)

_Last verified: 2026-11-03_

## Status

Fixed in Engram PR 2410 (release 0.72.3), plus PR 2403 (reverify drain) and
engram-infra PR 1736 (rate-based swap + slow-maintenance alerts). The bulk
import 4x storage cause is open; R8 is the fix.

## What This Is

How background/maintenance jobs (cron, Oban, boot probes) loaded prod RDS hard
enough to push pages to swap, how to diagnose it, and the rules every new job
must follow so it does not happen again.

## Environment

SaaS prod RDS `engram-prod`: db.t4g.medium (4 GB RAM), database about 7.2 GB.
Maintenance jobs connect as role `engram_maintenance` (see
`docs/context/maintenance-db-role.md`).

## Symptom: SwapUsage alerts while RAM is "not maxed"

- Swap is residue. Pages pushed out during a burst stay swapped until touched,
  so the absolute `SwapUsage` stays high for hours after the burst ends.
  2026-11-03: 270 MB to 1.14 GB in 2 minutes at 04:34Z, then 500 to 1000 MB for
  hours with nothing running.
- `FreeableMemory` includes page cache, so it never looks tight. Do not read it
  as "we have headroom".
- Alert on the swap-out RATE (Enhanced Monitoring, CloudWatch log group
  `RDSOSMetrics`), not the absolute level. engram-infra PR 1736 added a
  rate-based swap alert and a slow-maintenance-seconds alert.

## Key Commands / Patterns (diagnosis)

1. **Which process:** Enhanced Monitoring `processList` in log group
   `RDSOSMetrics` (the stream name is the instance's `DbiResourceId`) names the
   backend (role `engram_maintenance`) and its RSS at the burst minute.
2. **Which query:** the Postgres slow log in CloudWatch,
   `/aws/rds/instance/engram-prod/postgresql` (threshold about 1 s).
3. **Aggregates:** Performance Insights via `aws pi describe-dimension-keys`.
   Group names are `db.sql_tokenized`, `db.user`, `db.wait_event`.
4. **Not available:** `engram_audit_ro` cannot read `pg_stat_statements`
   (permission denied on schema `extensions`). Use PI and the slow log instead.

## Causes found (2026-11-03 audit)

- `DataMigrationsRunner` nightly reverify walked every note. Now a drain (PR 2403).
- Hourly `CrdtBloatSweep` did a full heap scan, running close to its 15 s timeout.
- `TenancyGuard` boot probes seq-scanned tables whose only `user_id` indexes
  are partial (the planner cannot use a partial index for an unrestricted probe).
- `WarmCrdtHeads` and other jobs assumed a `notes(updated_at)` index. It does
  not exist, and adding one would break HOT updates on every save.
- A bulk agent import stored each note 4x (`notes` plus `note_bodies` copies).
  R8 is the fix.

## Fixes (PR 2410, release 0.72.3)

- Change feed reads `vaults.change_seq` plus the existing
  `(vault_id, seq, id)` index instead of scanning by timestamp.
- Sizes are BEFORE-trigger columns on `note_bodies`: zero extra row versions
  per save, enforced by a row-versions-per-save test.
- A 15-minute `BookkeepingDrain` works over partial indexes, bounded per run.
- Hourly canary, metric
  `engram_prom_ex_reliability_bookkeeping_canary_last_run_unix`.
- Daily jobs moved to the 10:00 to 11:15 UTC window.
- `cron_scan_bound_test` CI guard: every cron entry must be classified as
  bounded, so a new unbounded cron fails CI.
- `TenancyGuard` now uses a catalog + policy audit and an index-only probe.

## Rules for new jobs

1. No O(table) scans. Use an index-bounded predicate plus a per-run cap.
2. Never add an index on a column every save writes (for example
   `updated_at`): it disables HOT updates and bloats every save.
3. Prove the plan with an EXPLAIN plan test, not by eyeballing.
4. Telemetry for drift counts uses `sum`, not `counter`. A `counter` adds 1 per
   event and ignores the measured value.
5. Classify the job in `cron_scan_bound_test`.

## Failed Approaches / Dead Ends

- Reading absolute `SwapUsage` or `FreeableMemory` to judge memory pressure.
  Both mislead (residue and page cache).
- Querying PI with group names like `db.user.name`: wrong, use `db.user`.
- `pg_stat_statements` via `engram_audit_ro`: denied.
- Adding a `notes(updated_at)` index to make time-window jobs cheap: kills HOT.

## Gotchas

- Staging app metrics are not scraped (`/metrics` returns 401, no
  `METRICS_AUTH_TOKEN` set on staging), and staging logs are not in Grafana Loki
  (only `env=prod` ships). Read staging logs with `docker logs engram-saas` on
  FastRaid.

## References

- Engram vault: `50 Engineering/Job Load Audit 2026-11-03.md`
- Engram vault: `50 Engineering/_Superpowers Specs/2026-11-03-drift-proof-bookkeeping-design.md`
- `docs/context/maintenance-db-role.md`
- Engram PRs 2403, 2410; engram-infra PR 1736
