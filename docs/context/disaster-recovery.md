# Context Doc: Disaster Recovery & Backup Readiness

_Last verified: 2026-09-05 (live AWS + Qdrant Cloud read, launch-minimum)_

> **Why this exists:** "A backup that's never been restored isn't a backup." This is the launch-minimum DR runbook for engram prod (AWS account `751667630925`, region `us-east-1`). One paragraph per failure scenario; it **links** to the existing rotation runbooks rather than restating them. Tracks issue #255.

## Prod topology (data stores)

| Store | Identity | Backup mechanism | Verified state (2026-09-05, live) |
|-------|----------|------------------|------------------------------|
| **RDS Postgres** | `engram-prod` (PG 18.3, db.t4g.small, 20 GB, single-AZ) | Daily automated snapshots + PITR, 7-day retention, window 08:00–09:00 UTC | ✅ retention = 7d; **restore drill PASSED — RTO 7m34s, PITR RPO ~4 min, schema byte-identical** |
| **S3 attachments** | `engram-saas-prod-attachments-751667630925` | Bucket versioning, noncurrent versions expire at 30 days | ✅ versioning **Enabled**; delete→restore proof **PASSED** (see below) |
| **Qdrant Cloud** | `engram-saas-prod` cluster `0a4bef59-…`, free tier, 1 node, v1.18.2 | **NONE** — free tier has no scheduled backups | ❌ **no backups exist**; recovery is re-embed from Postgres (see below) |

Single-AZ is intentional at launch (RPO/RTO acceptable for a low-customer-count launch; multi-AZ promoted post-launch when traffic/SLO justify it — explicitly out of scope here).

## Verified backup posture

### RDS Postgres — automated snapshots + PITR ✅, restore drill PASSED

Automated snapshots ON, retention 7 days, backup window 08:00–09:00 UTC. Verified live 2026-09-05 via `aws rds describe-db-snapshots --snapshot-type automated`: one `available` snapshot per day for the full window.

**Drill run 2026-09-05 — measured actuals:**

| Metric | Measured | Method |
|---|---|---|
| **RTO (restore → `available`)** | **7 min 34 s** | `restore-db-instance-from-db-snapshot` at 08:37:59Z → status `available` at 08:45:33Z |
| **RPO (PITR)** | **≈ 4 min** | `LatestRestorableTime` 08:33:48Z read at 08:37:36Z |
| **RPO (snapshot only)** | ≤ 24 h | daily automated snapshot cadence |
| **Schema fidelity** | **byte-identical** | `pg_dump --schema-only` both sides, 2470 lines each, diff empty except pg_dump 18's per-invocation `\restrict`/`\unrestrict` nonce |

Restored `rds:engram-prod-2026-09-05-08-14` into `engram-prod-drill255` (db.t4g.small, same subnet group + SG, `--no-publicly-accessible`, `--backup-retention-period 0`), reached it through the SSM bastion, diffed, then deleted the instance with `--skip-final-snapshot --delete-automated-backups`. Total billable footprint: one db.t4g.small for ~20 min.

**7 min 34 s is the instance-ready number, not end-to-end DR.** Full recovery adds the `DATABASE_URL` cutover and an ECS service redeploy on top. Budget ~15 min end-to-end and re-measure if the DB ever grows past 20 GB — restore time scales with volume size.

**Content checks:** schema_migrations 51 rows, max version `20260902130000`; 39 tables, 144 indexes, 11 RLS policies, extensions `pg_stat_statements,plpgsql` — all identical to live prod. Row counts differed (restored 8271 notes / 19 vaults vs live 1885 / 11) and the delta reconciled exactly: 8 soft-deleted test vaults holding precisely 6386 notes were force-purged in prod at 08:43 by `CleanupVault` (`"force": true` jobs inserted 08:43:19–08:43:51 — the "delete permanently now" path), i.e. after the 08:14 snapshot. Live vault count matched on both sides. **Verify this kind of delta before accepting it** — a restore that silently holds different rows than you expect is the failure mode this drill exists to catch.

**Gotchas hit while running it, worth knowing before the real thing:**

- `engram-infra-operator` cannot restore (`rds:RestoreDBInstanceFromDBSnapshot` → `AccessDenied`). A real recovery runs from `engram-breakglass`.
- The bastion has a boot-time 60-minute auto-poweroff (`bastion.tf` user_data) and it stopped once mid-drill. `sudo shutdown -c` after connecting, or expect to restart it and re-establish the tunnel.
- A dead SSM port-forward can leave the local port bound, so the *next* tunnel silently fails to bind and your `psql` keeps talking to the **previous** host. Confirm which database you are on with `select pg_postmaster_start_time();` before trusting any comparison — a freshly restored instance shows a start time minutes old.

### S3 attachments — versioning ✅, delete→restore proof PASSED

Proof run 2026-09-05 against the live prod bucket with the `engram-breakglass` identity (the `engram-infra-operator` identity is control-plane only and gets `AccessDenied` on `s3:PutObject` — that separation is deliberate, do **not** broaden the operator policy):

1. `put-object` a 36-byte test object under `_dr-drill/` → version `QDY5Jd…`
2. `delete-object` (no version-id) → delete marker `lra2.O3…`; `get-object` then returns `NoSuchKey` ✅
3. `list-object-versions` shows the original version intact, delete marker latest ✅
4. `delete-object --version-id <delete-marker>` removes the marker
5. `get-object` returns the original; **md5 matches the source byte-for-byte** ✅
6. Test object and its version permanently deleted; bucket left clean (`_dr-drill/` prefix empty)

**Recovery window is 30 days, not forever.** The bucket lifecycle rule `expire-noncurrent-versions` sets `NoncurrentDays: 30`, so a deleted or overwritten attachment is recoverable for 30 days and then gone permanently. No cross-region replication at launch.

### Qdrant Cloud — NO backups; recovery is re-embed from Postgres

Verified live 2026-09-05 via the Qdrant Cloud management API and the cluster data API:

- Cluster config reports `"snapshotStorageClass": "emptyDir"` — snapshot storage is node-ephemeral, so even a manual snapshot does not survive node replacement.
- The management API's backup / backup-schedule endpoints return `404` for this account. Free tier does not include scheduled backups (see `engram-infra/docs/context/qdrant-prod-cluster.md` — "Standard tier unlocks scheduled backups"; paid tier is the fix if this ever needs to be a real backup).
- `GET /collections/engram_notes/snapshots` and `GET /snapshots` both return `[]`. **Zero snapshots exist.**
- Collection `engram_notes` holds **76,352 points**, status `green`.

This is acceptable **only because vectors are derived data** — Postgres is ground truth for note content, and every vector is reconstructable by re-embedding. It is not acceptable to treat Qdrant as a store of record for anything.

**Do not wait on `mix engram.reindex` (#173) — it does not exist.** The recovery path below uses mechanisms that are already deployed.

## Qdrant rebuild procedure (total collection loss)

1. **Clear the per-node collection memo on every running node.** `Engram.Vector.Qdrant.ensure_collection/2` memoises "this collection is ready" in `:persistent_term`. After an out-of-band drop, a running node keeps skipping the create and every upsert fails against a collection that no longer exists. Either run `Engram.Vector.Qdrant.forget_collection_memo()` on each node or force a new deployment/task replacement. **Skipping this step makes the rebuild silently fail.** The collection and its payload indexes are then recreated automatically on the first index call.
2. **Null the index hashes so the existing sweeper sees every note as stale:**

   ```sql
   UPDATE notes
      SET embed_hash = NULL, dense_indexed_hash = NULL
    WHERE kind = 'note' AND deleted_at IS NULL;
   ```

   Same shape the billing downgrade path already uses (`Engram.Billing` → `IndexCap.revoke_dense_index/1`), so this is a proven mechanism, not a new one.
3. **Wait.** `Engram.Workers.ReconcileEmbeddings` runs on the `*/15 * * * *` Oban cron and enqueues at most `@batch_size = 500` `EmbedNote` jobs per tick.

**RTO for a full rebuild ≈ 1 hour** at current volume: ~1,574 live notes ÷ 500 per tick × 15 min ≈ 4 ticks. Search is degraded (keyword-only) for that window; note reads and writes are unaffected throughout. To go faster, invoke `ReconcileEmbeddings.perform/1` in a loop from a remote console — the per-tick cap is the binding constraint, not embed throughput. A full rebuild re-bills Voyage for the whole corpus; budget for it before starting.

> The batch is **notes per tick, not chunks**. An earlier revision of this doc read the Qdrant point count (76,352, taken before an unrelated purge of 8 test vaults) as a note count and put the RTO at 38 hours. Measured 2026-09-05: ~10,400 chunk rows over ~1,574 live notes, about 7 chunks per note. Re-derive from `select count(*) from notes where kind = 'note' and deleted_at is null` rather than from the collection size.

**This whole procedure is for TOTAL collection loss only.** For partial divergence — the far likelier case, and what a Postgres restore produces — do not null every hash. `Engram.Workers.OrphanSweep` reconciles both directions against Qdrant's real point ids on its 05:00 UTC daily tick and flags only the notes that actually lost their points (#1576). Enqueue it on demand instead of waiting.

## DR scenarios

Each is one paragraph and links out to the canonical runbook. Don't restate rotation procedures here — they drift.

**AWS region down (us-east-1).** Single-region at launch — there is no failover. Wait for AWS recovery; post status to the public status page (#252) and hold. Multi-region failover is deliberately out of scope until traffic/SLO justify it.

**RDS Postgres data loss / corruption.** Restore from automated snapshot, or point-in-time to any moment within the 7-day window (RPO ≈ 4 min), to a new instance; then cut the app over by repointing `DATABASE_URL`. Drilled 2026-09-05: **7 min 34 s to a usable instance, schema byte-identical** — actuals and the gotchas that cost time are in the RDS section above. Restore from `engram-breakglass`; the operator identity is not authorized.

**A Postgres restore is not finished until Qdrant is reconciled.** Restoring rolls back the note data *and* the `embed_hash`/`dense_indexed_hash` bookkeeping about what was sent to Qdrant, together — so they stay mutually consistent while Qdrant does not. Every note re-indexed between the restore point and the failure has vectors under ids that no longer exist, and still reads as freshly indexed. Left alone those notes are silently unsearchable forever; `ReconcileEmbeddings` never notices, because it only ever compares two Postgres columns.

Enqueue `Engram.Workers.OrphanSweep` immediately after the cutover rather than waiting for its 05:00 UTC tick (#1576). It reconciles both directions against Qdrant's real point ids: strays get deleted, and notes whose points are gone get their index hashes nulled so `ReconcileEmbeddings` rebuilds exactly those. **Do not blind-rebuild the whole corpus for this** — the sweep identifies the diverged set, so recovery is proportional to the damage window (minutes of writes at a ~4 min RPO), not 76k notes. Watch for `orphan_sweep aborting: missing-point ratio implies a bad authority` in the logs: that means Qdrant is unreachable or repointed, and nothing was flagged. Fix Qdrant, then re-run.

**S3 attachment loss / accidental delete.** Versioning is on — remove the delete marker (or restore the prior version) for the affected key; proven above. Bulk loss: re-list versions and restore. Recoverable for 30 days only; no cross-region replication at launch.

**Qdrant Cloud cluster lost or account compromised.** Rotate the Qdrant API key (`engram-infra/docs/context/qdrant-prod-cluster.md`), then rebuild via the procedure above — there is nothing to restore from. Search is keyword-only until the rebuild completes; reads and writes of note content are unaffected (Postgres is ground truth).

**Voyage AI key leaked.** Rotate via SOPS — see `engram-infra/docs/context/sops-pattern.md` (atomic env rotation). Embedding pauses until the new key propagates; existing vectors are unaffected.

**Paddle account suspended.** Service continues; billing/revenue paused; customer data unaffected (Paddle is Merchant of Record — revenue data lives in Paddle's dashboard, exportable there). No engram-side data action required.

**Encryption master key compromised.** Rotate the master key via the T3.5 procedure — see `docs/context/encryption-operations.md` (master-key rotation + BootCanary). Per-user DEKs are re-wrapped; note plaintext is never exposed.

## Out of scope (launch-minimum)

Multi-region failover drills, cross-AZ HA testing, full simulation of non-RDS scenarios, and a Paddle data-export procedure are all deferred — see #255 for rationale. Drill RDS only; trust the existing rotation runbooks (linked above) for the rest.

## Acceptance (#255) — COMPLETE

- [x] S3 versioning ON + delete→restore proof (2026-09-05, bytes matched)
- [x] Qdrant snapshot mechanism verified + retention noted (verdict: none exist; rebuild procedure documented above)
- [x] RDS snapshot retention verified live (7 days, snapshots present, PITR within ~4 min)
- [x] RDS restore drill → throwaway instance → schema diff → RTO 7m34s, RPO ~4 min (2026-09-05)
- [x] Cross-linked from `engram-workspace/docs/context/launch-day-procedure.md` pre-flight row 10 + workspace `CLAUDE.md`

**Re-drill when** the DB grows materially past 20 GB, the instance class changes, or multi-AZ is promoted — restore time scales with volume size and the recorded RTO stops being true.
