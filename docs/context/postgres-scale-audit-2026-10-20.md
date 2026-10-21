# Context Doc: Postgres scale audit (what blocks 100k users)

_Last verified: 2026-10-20_

## Status
Audit complete, nothing fixed yet. Static read of `origin/main` 43febde99 plus read-only prod stats (413 users, 228 with notes, 34.9k notes, DB 1.2 GB, pg_stat since 2026-06-11, PI 7d). Line numbers are as of 43febde99; re-grep before editing.

## What This Is
Ranked list of the Postgres costs that break first as SaaS grows, each tied to file:line and the prod number that confirms it, plus the recipe for measuring prod again without rediscovering access.

## Environment
- RDS db.t4g.small (2 vCPU burstable, 2 GB RAM), PG 18.3, single-AZ, gp3 20 GB (autoscale cap 100 GB), PI on (7d), backups 7d.
- Load is tiny today: 0.02 AAS avg, peaks 0.4-0.67, CPU 7%, credits full. Memory is not: FreeableMemory min 38 MB (avg 162 MB), SwapUsage ~240 MB baseline, max 804 MB. 77 idle backends (71 engram_app). shared_buffers 412 MB.
- Settings: random_page_cost 4 (wrong for gp3, use 1.1), work_mem 4 MB, maintenance_work_mem 64 MB, idle_in_transaction_session_timeout 24h (effectively none), autovacuum_vacuum_cost_limit 200, max_connections 181, default_toast_compression lz4, jit off.
- Repo config (`config/runtime.exs:809-821`): no `parameters:`, no timeouts, no queue_target. RDS param group (`engram-infra/main/envs/prod/rds.tf`) sets only `log_min_duration_statement=1000`, `log_lock_waits=1`.

## Ranked findings (fix in this order)

| # | Finding | Code | Prod evidence | Fix |
|---|---|---|---|---|
| 0 | **Oban queue-count poll + 7-day retention. #1 DB cost** | PromEx `Plugins.Oban` registered with no opts `lib/engram/prom_ex.ex:24` (poll_rate default 5000 ms, `deps/prom_ex/lib/prom_ex/plugins/oban.ex:96`, query `:433-447`); worker role only since #1497 (`config/runtime.exs:966`). Pruner `max_age: 7 * 24 * 3600` `config/config.exs:183` | `SELECT queue,state,count(id) FROM oban_jobs GROUP BY 1,2` 3755 s, 435k calls, 8.6 ms mean; 28% of PI db.load, #1 at every peak; oban_jobs 3.9M seq scans, 21.9B tuples read; 160k retained rows | `poll_rate: 60_000`; Pruner 6h; autovacuum scale 0.01 + fillfactor 85 on oban_jobs; drop `oban_jobs_meta_index` (1 scan). `connection_created` 30-day unique (`workers/connection_created.ex:25`) is already silently cut to 7d |
| 1 | **ReconcileEmbeddings full seq scan every 5 min** (even with 0 eligible rows) | `workers/reconcile_embeddings.ex:124-156` (eligible), `:174-188` (UPDATE), keyword twin `:368-398`; `data_migrations/index_versions.ex:55-59`; cron `2-59/5` | slowest app query, 39 ms mean at 34.9k notes; notes 87k seq scans / 180M tuples (~2 per tick over 131 days); linear ~9.4 s/tick at 8.4M notes | `CREATE INDEX CONCURRENTLY notes_reconcile_due ON notes (updated_at) WHERE kind='note' AND deleted_at IS NULL AND (embed_hash IS NULL OR embed_hash <> content_hash OR dense_indexed_hash IS NULL)`, then drop `idx_notes_embed_pending`; exclude budget-parked rows from the predicate (reopen on upgrade webhook) |
| 2 | **Path lookup cannot use the path index** (no `kind='note'`, partial index `notes_user_vault_path_v2` needs it) | `notes.ex:3262-3267` `note_by_path_query/3`, `note_ids_at/3` `:3287`, `do_note_ids_for_paths/4` `:3361`; callers 683, 1471, 1635, 2722, 2885, 3245, 3524, 3529, 3810; MCP get_notes loop `mcp/handlers.ex:352` | NOT YET CONFIRMED. Consistent: `fm_timestamp` (261 scans) and `fm_created` (26) get scans though nothing filters on them. Settle with EXPLAIN + `idx_scan` of `notes_user_vault_path_v2` | add `n.kind == "note"` to the three queries (no DDL). Also `(vault_id, path_hmac) WHERE deleted_at IS NOT NULL` for `recently_deleted_twin?` `notes.ex:3317` and `workers/rewrite_note_links.ex:263` |
| 3 | **No timeouts** | `config/runtime.exs:809-821` | idle_in_transaction 24h; PI `Client:ClientRead` 0.0055 AAS (txn open while app works) | Repo `parameters: [statement_timeout: "15000", idle_in_transaction_session_timeout: "60000", lock_timeout: "5000"]` (startup packet, 0 round trips). Verify prod `DATABASE_SSL_MODE=verify-full` (default `verify_none`, `runtime.exs:797-807`) |
| 3b | **`SET statement_timeout=$1` 32.6M calls is NOT ours** | grep of lib/config/priv/native/deps/engram-infra finds none | 2.9/s, next to the 11.3M-call pg_stat_activity exporter query | attribute by role (`pg_stat_statements JOIN pg_roles`) first; likely Grafana/Alloy exporter config |
| 4 | **Per-transaction tenant round trips** | `with_tenant` `lib/engram/repo.ex:268-330`, set_config `:295-297` | `set_config(tenant), set_config(role)` PI #2 at 15% of load | fold per-call overrides into that SELECT; global defaults via `parameters:` |
| 5 | **Refresh-token tables grow per 15-min rotation, cleanup seq-scans** | OAuth: rotation copies 10 grant fields `oauth.ex:1241-1260`, delete at expiry+7d `:1617-1632`, one cross-user txn `:1678-1700`. Device: `auth/device_flow.ex:254-257`, `:290-295` | not measured (Q6) | `revoked_at` partial indexes on both; compact consumed OAuth rows after 24h; `oauth_grants` table; batch per user; delete expired-unrevoked device rows |
| 6 | **Capacity: 15 KB per note, 95% of it two ciphertexts** | `crdt_state` + `content` both on notes; readers listed in `crypto.ex:435-437`, `:492`, `:670` | avg row 15.0 KB: crdt_state 7123 B + content 7062 B; 543 MB TOAST for 34.9k notes | move `crdt_state_*` + `crdt_head` to 1:1 `note_crdt_state` (`vault_index_states` proves the pattern: 10 KB blob, 99% HOT). Do NOT derive content from the doc or drop cold state (mints a second CRDT lineage: data loss) |
| 7 | **SELECT * drags crdt_state on every catch-up page** | `notes.ex:4376-4380` (`:all` default `:4360`, used by `sync.ex:42`); budget probes only content `:4568-4571`; also `:3130`, `:5641`, `:4736` | follows from #6 | explicit `@note_sync_fields`; budget `pg_column_size(crdt_state_ciphertext)` where state is needed |
| 8 | **Hourly per-user tenant loops** | `backfill/tenant_scan.ex:58-80`; `workers/backfill_crdt_head.ex:65-76`; `crdt_head` NULLed per append `notes/crdt_persistence.ex:330-337` | not measured | `Repo.maintenance()` discovery + `notes (vault_id) WHERE crdt_head IS NULL AND kind='note' AND deleted_at IS NULL` |
| 9 | **Dead indexes** | see list below | prod scan counts below | drop after a clean week of `idx_scan = 0` |
| 10 | **Unbounded vault delete txn** | `workers/cleanup_vault.ex:190-261` | n/a | id-ordered batches of 1-5k, children first |
| 11 | **Data-DML migrations hold ACCESS EXCLUSIVE** (NO FORCE RLS pattern) | `20260827000000`, `20261004120000`, `20260926090000` | n/a | `data_migrations` ledger on `Repo.maintenance()`, id-ranged batches |
| 12 | **Tombstones never purged** (rename inserts a fresh tombstone; folder rename one per note) | `notes.ex:3703-3742`, `:3832-3841`, `:5880`; pull has no deleted_at filter `:4364` | 4871 trashed rows (14%), 14 MB, 227 older than 30 days | horizon GC; check epic #609 trash/restore needs first |
| 13 | **Non-HOT update amplification** (3-5 notes versions per embed run, 18 indexes, fillfactor 100) | `crash_guard.ex:99-111`, `embed_note.ex:766-782`, `indexing.ex:412`, `reconcile_embeddings.ex:188` | not measured (Q3) | `note_index_state` side table, then notes fillfactor 90 |
| 14 | **Per-row NOTIFY triggers** (global commit lock) | `20261009130000`, `20261009120001`, `20261015030000`, `20260612100000`; Oban Postgres notifier `config/config.exs:83-89` | `Lock:transactionid` 0.0003 AAS; invisible at current load | statement-level trigger or PubSub; `Oban.Notifiers.PG` now that clustering is live |

New findings from prod, not in the static pass:
- **crdt_update_log appends are state-sized**: avg update 21 KB, 74 MB TOAST for 1.4k rows, and `crdt_update_log:update` is not in the zstd policy (`crypto/envelope.ex:132-139`). Add `{:crdt_update_log, :update, :zstd}` and find out why appends are full state (`crdt_persistence.ex`, see `crdt-lineage-doubling.md`).
- **client_logs**: 206k rows / 95 MB for 413 users, highest Ecto mean per source (9.1 ms). Pruner `workers/client_logs_pruner.ex:35-50` filters `created_at` with no index (dropped `20260629230000`): prune by uuidv7 `id` range. `list_logs` `logs.ex:241-268` wants `(user_id, ts DESC)`. Rows are also re-emitted to Loki (`logs.ex:137`); consider 7-day retention.
- **Per-vault seq hot row**: `UPDATE vaults SET change_seq` 112k calls, 2 ms mean (`vaults.ex:77-86`, `lock_for_write` `notes.ex:2372-2378`). `vaults_changed` trigger does `to_jsonb(OLD)`/`to_jsonb(NEW)` per bump.
- Instance: random_page_cost 4 -> 1.1; autovacuum_vacuum_cost_limit 200 -> 1000-2000; 77 idle backends on 2 GB RAM argues for SMALLER pools (matches `prod-db-connection-budget.md`).
- Other Ecto means (PromEx 1d): oban_jobs 7.7 ms, terms_versions 5.6 ms (5-row table, 1.5 ms queue), chunks 3.8, notes 1.9; p99 35-47 ms.

## Dead / near-dead indexes (scans since 2026-06-11)
- 0: `notes_tags_hmac_index` (GIN, 1.0 MB), `notes_user_id_vault_id_basename_hmac_path_length_index` (4-col, 5.6 MB; keep the 3-col live partial, prod overruled the static guess), `users_email_lower_index`, `users_plan_id_index`, `vaults_user_id_default_index`, `device_authorizations` user/viewer, `oauth_authorization_codes` client/user.
- Near 0: notes `fm_created` 26, `fm_timestamp` 261, `oban_jobs_meta_index` 1, attachments 4-col basename 11 (992 KB), `client_logs_vault_id_ts_index` 4, `client_logs_user_id_index` 39 (6 MB).
- Used but suspect (chunks scans were mostly this audit's ad-hoc research, recheck after reset): `idx_chunks_user` 1127, `chunks_vault_id_index` 3727. The real chunks index is `(note_id, position)` at 14.7M scans.
- Left-prefix redundant: `idx_attachments_user` (covered by 5 `(user_id, vault_id, ...)` indexes). FKs without an index: none.

## Byte waste (measured)
- notes hex hashes as text: content_hash 56, embed_hash 51, embed_started_hash 55, dense_indexed_hash 40, crdt_head 37 avg B (sha256 bytea is 33).
- chunks avg 171 B: `context_hmac` hex 65 B, 5 uuids 80 B, `token_count` int8, `heading_path` 100% NULL (dead). `qdrant_point_id` never equals `id`, so a PK swap must use `(note_id, position)` or `qdrant_point_id`.
- client_logs: `stack` 487 B avg, 98% NULL; `device_id`/`conn_id` uuid-as-text 37 B.
- vaults: `description` 100% NULL; `slug` plaintext and `slug_hmac` both unique-indexed.
- users: 9 columns 100% NULL in SaaS. Leave them, they are self-host features.
- `SET STORAGE EXTERNAL` on ciphertext columns: lz4 TOAST compression on ciphertext gains ~0 and burns CPU on every write. Never `SET COMPRESSION lz4` on them.

## 100k-user projection (linear from 413 users)
Distribution is very skewed: notes/user p50 = 1, p90 = 70, p99 = 1158, max 10000.
- notes ~8.4M rows, ~160 GB (TOAST dominated).
- chunks ~134M rows, ~56 GB incl. indexes.
- oban_jobs at 7-day retention ~39M rows: the 5 s queue/state count becomes a multi-second seq scan run every few seconds.
- client_logs ~50M rows, ~23 GB at 30-day retention.
- Reconcile tick ~9.4 s per 5 min.
- Verdict: 20 GB storage / 100 GB autoscale cap and a 2 GB burstable instance do not survive. Fixes #0-#7 recover most of the bytes and nearly all of the measured CPU.

## Key Commands / Patterns (HOW TO MEASURE)

### Access
Bastion + SSM port forward + IAM auth token as `engram_audit_ro`: follow `engram-infra/docs/context/prod-db-readonly-access.md` exactly.
- The first connect right after `start-session` FAILS. Wait ~30 s, then probe the forward with a raw SSL request before running queries.
- `python3 -I` drops the user site-packages, so `psycopg2` is not found. Run the audit script without `-I` (keep the script outside any downloaded dir).

### Bytes per column under RLS
`pg_stats` hides RLS tables from engram_audit_ro, so `avg_width` is unavailable. Loop tenants: per user, `SELECT set_config('app.current_tenant', $uid, false)` then `SELECT count(*), sum(pg_column_size(col)) ... FROM notes`, and sum across tenants. Table/TOAST/index totals come from `pg_relation_size` / `pg_total_relation_size(reltoastrelid)` / `pg_indexes_size`, which RLS does not hide.

### Compression check (zstd envelope landing?)
`SELECT octet_length(content_nonce) fmt, count(*), avg(pg_column_size(content_ciphertext)) FROM notes WHERE content_nonce IS NOT NULL GROUP BY 1` (per tenant, as above). Nonce 13 bytes (`pg_column_size` 14) = zstd-compressed envelope format 1; 12 (13) = legacy uncompressed. Prod content and crdt_state nonces are 13, so compression IS landing and the ~7 KB per column is post-compression. Same for `crdt_state_nonce`.

### Top statements
engram_audit_ro has no USAGE on schema `extensions`, so `extensions.pg_stat_statements` is unreadable. Use either:
- Grafana metrics `pg_stat_statements_top_*` (label `statement`; filter to one `task` or series duplicate), or
- `aws pi describe-dimension-keys` against DbiResourceId `db-R3RIT55BAJX4J7GI4KXK3AZ2LA` (Performance Insights, 7d), grouped by `db.sql_tokenized` or `db.wait_event`.

### Instance memory
CloudWatch `FreeableMemory` / `SwapUsage` with `--profile engram-audit`. A 7-day range needs `--period 600` or more (1440-datapoint limit per request).

### Still-open queries (run next time)
- `idx_scan` of `notes_user_vault_path_v2` + EXPLAIN (ANALYZE, BUFFERS) of `note_by_path_query/3` with and without `kind='note'` (finding #2).
- HOT ratio: `n_tup_upd, n_tup_hot_upd, n_dead_tup` from `pg_stat_user_tables` for notes, oban_jobs, usage_meters, vaults, note_revisions, chunks (finding #13).
- Token growth: rows per `family_id` in oauth_refresh_tokens; revoked vs total in device_refresh_tokens (finding #5).
- `SET statement_timeout` attribution by role (finding #3b).
- Per-day event volume for analytics_events and client_logs.

## Failed Approaches / Dead Ends
- `pg_stats.avg_width` for byte sizing: RLS hides the tables. Use per-tenant `pg_column_size`.
- `extensions.pg_stat_statements` directly as engram_audit_ro: permission denied on schema.
- Static guess that the 3-col basename partial was dead and the 4-col one used: prod says the reverse.
- Static guess that 7 KB columns meant compression was off: nonce lengths prove it is on.
- Hunting engram code for `SET statement_timeout`: it is not ours.

## Gotchas
- The audit pollutes its own evidence: the `pg_column_size`/chunks scans appear in pg_stat_statements top-mean, and they are the 04:20-04:45 MDT 2026-10-20 CPU/IO spike (63% CPU, 320 read IOPS). Exclude that window and those statements; chunks seq_scan counts are mostly this audit.
- The #1 total-time statement is the Grafana exporter's own pg_stat_statements query (6694 s, 25 ms mean), and #3 is the pg_stat_activity exporter (1936 s, 11.3M calls). Monitoring is a top DB consumer; rate-limit it too.
- pg_stat counters run from the last reset (2026-06-11 here). Check `stats_reset` in `pg_stat_database` before reading idx_scan as "unused".

## References
- `engram-infra/docs/context/prod-db-readonly-access.md` (access)
- `docs/context/prod-db-connection-budget.md` (workspace; FreeableMemory decay, pool sizing)
- `docs/context/crdt-lineage-doubling.md`, `docs/context/crdt-bloat-measurement-traps.md`
- `docs/context/migrations-force-rls-data-dml.md`, `docs/context/data-migrations-ledger.md`
- `crypto/envelope.ex:95-139` (zstd policy, CompressionGate), `config/config.exs:71` (`:envelope_compression`)
