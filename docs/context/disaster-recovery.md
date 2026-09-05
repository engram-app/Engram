# Context Doc: Disaster Recovery & Backup Readiness

_Last verified: 2026-09-05 (live AWS + Qdrant Cloud read, launch-minimum)_

> **Why this exists:** "A backup that's never been restored isn't a backup." This is the launch-minimum DR runbook for engram prod (AWS account `751667630925`, region `us-east-1`). One paragraph per failure scenario; it **links** to the existing rotation runbooks rather than restating them. Tracks issue #255.

## Prod topology (data stores)

| Store | Identity | Backup mechanism | Verified state (2026-09-05, live) |
|-------|----------|------------------|------------------------------|
| **RDS Postgres** | `engram-prod` (PG 18.3, db.t4g.small, 20 GB, single-AZ) | Daily automated snapshots + PITR, 7-day retention, window 08:00–09:00 UTC | ✅ retention = 7d; snapshots present for each of the last 7 days; `LatestRestorableTime` within ~5 min of now |
| **S3 attachments** | `engram-saas-prod-attachments-751667630925` | Bucket versioning, noncurrent versions expire at 30 days | ✅ versioning **Enabled**; delete→restore proof **PASSED** (see below) |
| **Qdrant Cloud** | `engram-saas-prod` cluster `0a4bef59-…`, free tier, 1 node, v1.18.2 | **NONE** — free tier has no scheduled backups | ❌ **no backups exist**; recovery is re-embed from Postgres (see below) |

Single-AZ is intentional at launch (RPO/RTO acceptable for a low-customer-count launch; multi-AZ promoted post-launch when traffic/SLO justify it — explicitly out of scope here).

## Verified backup posture

### RDS Postgres — automated snapshots + PITR ✅ (restore drill still owed)

Automated snapshots ON, retention 7 days, backup window 08:00–09:00 UTC. Verified live 2026-09-05 via `aws rds describe-db-snapshots --snapshot-type automated`: one `available` snapshot per day for the full window.

- **RPO** ≈ 5 minutes. PITR is enabled by the same retention setting, so the floor is the transaction-log granularity, not the 24 h snapshot cadence. `LatestRestorableTime` tracked ~5 min behind wall clock at verification time.
- **RTO** — not yet measured. Estimated tens of minutes for a 20 GB single-AZ restore-to-new-instance plus the `DATABASE_URL` cutover, but **estimated is not measured**.

**The restore drill (restore snapshot → throwaway instance → schema diff → record RPO/RTO actuals) is still outstanding.** It is the last open acceptance item on #255 and the only one that provisions billable infrastructure. Paste the actuals into this section when it runs.

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

**RTO for a full rebuild ≈ 38 hours** at current volume: 76,352 notes ÷ 500 per tick × 15 min. Search is degraded (keyword-only) for that whole window; note reads and writes are unaffected throughout. To go faster, invoke `ReconcileEmbeddings.perform/1` in a loop from a remote console rather than waiting on cron ticks — the per-tick cap is the binding constraint, not embed throughput. Re-embedding 76k notes re-bills Voyage for the full corpus; budget for it before starting.

## DR scenarios

Each is one paragraph and links out to the canonical runbook. Don't restate rotation procedures here — they drift.

**AWS region down (us-east-1).** Single-region at launch — there is no failover. Wait for AWS recovery; post status to the public status page (#252) and hold. Multi-region failover is deliberately out of scope until traffic/SLO justify it.

**RDS Postgres data loss / corruption.** Restore from automated snapshot, or point-in-time to any moment within the 7-day window (RPO ≈ 5 min), to a new instance; then cut the app over by repointing `DATABASE_URL`. The drill that proves this end-to-end is the outstanding #255 item; once run, paste the RPO/RTO actuals into the RDS section above.

**S3 attachment loss / accidental delete.** Versioning is on — remove the delete marker (or restore the prior version) for the affected key; proven above. Bulk loss: re-list versions and restore. Recoverable for 30 days only; no cross-region replication at launch.

**Qdrant Cloud cluster lost or account compromised.** Rotate the Qdrant API key (`engram-infra/docs/context/qdrant-prod-cluster.md`), then rebuild via the procedure above — there is nothing to restore from. Search is keyword-only until the rebuild completes; reads and writes of note content are unaffected (Postgres is ground truth).

**Voyage AI key leaked.** Rotate via SOPS — see `engram-infra/docs/context/sops-pattern.md` (atomic env rotation). Embedding pauses until the new key propagates; existing vectors are unaffected.

**Paddle account suspended.** Service continues; billing/revenue paused; customer data unaffected (Paddle is Merchant of Record — revenue data lives in Paddle's dashboard, exportable there). No engram-side data action required.

**Encryption master key compromised.** Rotate the master key via the T3.5 procedure — see `docs/context/encryption-operations.md` (master-key rotation + BootCanary). Per-user DEKs are re-wrapped; note plaintext is never exposed.

## Out of scope (launch-minimum)

Multi-region failover drills, cross-AZ HA testing, full simulation of non-RDS scenarios, and a Paddle data-export procedure are all deferred — see #255 for rationale. Drill RDS only; trust the existing rotation runbooks (linked above) for the rest.

## Remaining acceptance (#255)

- [x] S3 versioning ON + delete→restore proof (2026-09-05, bytes matched)
- [x] Qdrant snapshot mechanism verified + retention noted (verdict: none exist; rebuild procedure documented above)
- [x] RDS snapshot retention verified live (7 days, snapshots present, PITR within ~5 min)
- [ ] **RDS restore drill → throwaway instance → schema diff → record RPO/RTO actuals here** (billable; needs a human at the keyboard)
- [x] Cross-linked from `engram-workspace/docs/context/launch-day-procedure.md` pre-flight row 10 + workspace `CLAUDE.md`
