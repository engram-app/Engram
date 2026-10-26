# Context Doc: Disaster Recovery & Backup Readiness

_Last verified: 2026-09-05 (live AWS + Qdrant Cloud read, launch-minimum). Qdrant section updated 2026-10-25 from TF._

> **Why this exists:** "A backup that's never been restored isn't a backup." This is the launch-minimum DR runbook for engram prod (AWS account `751667630925`, region `us-east-1`). One paragraph per failure scenario; it **links** to the existing rotation runbooks rather than restating them. Tracks issue #255.

## Prod topology (data stores)

| Store | Identity | Backup mechanism | Verified state (2026-09-05, live) |
|-------|----------|------------------|------------------------------|
| **RDS Postgres** | `engram-prod` (PG 18.3, db.t4g.small, 20 GB, single-AZ) | Daily automated snapshots + PITR, 7-day retention, window 08:00–09:00 UTC | ✅ retention = 7d; **restore drill PASSED — RTO 7m34s, PITR RPO ~4 min, schema byte-identical** |
| **S3 attachments** | `engram-saas-prod-attachments-751667630925` | Bucket versioning, noncurrent versions expire at 30 days | ✅ versioning **Enabled**; delete→restore proof **PASSED** (see below) |
| **Qdrant Cloud** | `engram-saas-prod-v3` (serves `QDRANT_URL`; mx1, 1 node, v1.19.2), plus `engram-saas-prod` and `-v2` | Cloud backups (volume snapshots), daily 15:00 UTC, 14-day retention, every prod cluster | ✅ schedules in TF with `delete_backups_on_destroy = false` (engram-infra `main/envs/prod/qdrant.tf`, checked 2026-10-25); **restore not drilled**. Re-embed from Postgres is the fallback (see below) |

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

**Verify row-count deltas before accepting a restore.** The 2026-09-05 drill's notes/vaults differed from live and reconciled exactly to a force-purge that ran after the snapshot. A restore that silently holds different rows than you expect is the failure mode the drill exists to catch.

**Gotchas hit while running it, worth knowing before the real thing:**

- `engram-infra-operator` cannot restore (`rds:RestoreDBInstanceFromDBSnapshot` → `AccessDenied`). A real recovery runs from `engram-breakglass`.
- The bastion has a boot-time 60-minute auto-poweroff (`bastion.tf` user_data) and it stopped once mid-drill. `sudo shutdown -c` after connecting, or expect to restart it and re-establish the tunnel.
- A dead SSM port-forward can leave the local port bound, so the *next* tunnel silently fails to bind and your `psql` keeps talking to the **previous** host. Confirm which database you are on with `select pg_postmaster_start_time();` before trusting any comparison — a freshly restored instance shows a start time minutes old.

### S3 attachments — versioning ✅, delete→restore proof PASSED

Proof run 2026-09-05 with the `engram-breakglass` identity: put, delete, confirm `NoSuchKey`, remove the delete marker, and the original came back md5-identical. The `engram-infra-operator` identity is control-plane only and gets `AccessDenied` on `s3:PutObject`; that separation is deliberate, do **not** broaden the operator policy.

**Recovery window is 30 days, not forever.** The bucket lifecycle rule `expire-noncurrent-versions` sets `NoncurrentDays: 30`, so a deleted or overwritten attachment is recoverable for 30 days and then gone permanently. No cross-region replication at launch.

### Qdrant Cloud: daily Cloud backups; re-embed is the fallback

Read 2026-10-25 from engram-infra `origin/main:main/envs/prod/qdrant.tf` (TF config, not a live API read):

- Every prod cluster (`engram`, `engram_v2`, `engram_v3`; v3 is the one behind `QDRANT_URL`) has a `qdrant-cloud_accounts_backup_schedule`: `cron_expression = "0 15 * * *"` (daily 15:00 UTC), `retention_period = "336h"` (14 days).
- `delete_backups_on_destroy = false` on each cluster AND each schedule, so destroying either keeps the restore points.
- Cloud backups are CSI volume snapshots taken by the cloud layer, not the Qdrant snapshot API, so they use no cluster-local disk ([Qdrant docs: migration and recovery options](https://qdrant.tech/documentation/migration-recovery-options/)). RPO is up to 24 h.
- **No restore has been drilled.** Until one is, treat the RTO as unknown.

**Restore route (cluster lost or collection corrupted):**

1. Restore the newest good Cloud backup **into a NEW cluster**. A restore resets the package AND the Qdrant version to what the backup recorded, and the restore must stay on the same provider and region; restoring in place also takes the cluster down for the duration (see the comment on `engram` in `qdrant.tf`).
2. Re-point Terraform in an engram-infra PR: `QDRANT_URL` to the new cluster, and its API key in SOPS (`qdrant_api_key`) / SSM. Prod moves when that PR applies and ECS rolls.
3. Let the app reconcile: the boot reconcile re-applies strict mode, quotas and the layout, and `Engram.Workers.OrphanSweep` repairs what changed after the backup (enqueue it; the `force` override in the Postgres-restore paragraph below applies if a day-old backup trips its 10% abort). Writes between the backup and the loss are re-indexed only for notes the sweep flags.

If no backup is usable, fall back to the full rebuild below. That fallback is acceptable **only because vectors are derived data**: Postgres is ground truth for note content, and every vector is reconstructable by re-embedding. It is not acceptable to treat Qdrant as a store of record for anything.

**Do not wait on `mix engram.reindex` (#173) — it does not exist.** The recovery path below uses mechanisms that are already deployed.

## Qdrant rebuild procedure (total collection loss)

1. **Clear the per-node collection memo on every running node.** `Engram.Vector.Qdrant.ensure_collection/2` memoises "this collection is ready" in `:persistent_term`. After an out-of-band drop, a running node keeps skipping the create and every upsert fails against a collection that no longer exists. Either run `Engram.Vector.Qdrant.forget_collection_memo()` on each node or force a new deployment/task replacement. **Skipping this step makes the rebuild silently fail.** The collection and its payload indexes are then recreated automatically on the first index call.
2. **Null the index hashes so the existing sweeper sees every note as stale:**

   ```sql
   UPDATE notes
      SET embed_hash = NULL, dense_indexed_hash = NULL
    WHERE kind = 'note' AND deleted_at IS NULL;
   ```

   Same shape the former index-cap downgrade sweep used (`IndexCap.evict_over_cap/1`, removed with the cap on 2026-10-17), so this is a proven mechanism, not a new one.
3. **Wait, or kick.** `Engram.Workers.ReconcileEmbeddings` runs every 5 minutes (`2-59/5`) and queues every stale note in one sweep, no per-tick cap. `ReconcileEmbeddings.kick()` from a remote console starts a sweep now.

**RTO for a full rebuild ≈ the embed queue's drain time**, not a cron cadence: the sweep queues the whole corpus at once, and `embed` concurrency at backfill priority sets the rate. Measured on the 0.42.0 rebuild: a 500-note batch drained in ~2 min, so ~1,574 live notes is roughly 6-10 min plus Voyage 429 snoozes. Search is degraded (keyword-only) for that window; note reads and writes are unaffected throughout. A full rebuild re-bills Voyage for the whole corpus; budget for it before starting.

> Count **notes, not chunks**. An earlier revision of this doc read the Qdrant point count (76,352, taken before an unrelated purge of 8 test vaults) as a note count and put the RTO at 38 hours. Measured 2026-09-05: ~10,400 chunk rows over ~1,574 live notes, about 7 chunks per note. Re-derive from `select count(*) from notes where kind = 'note' and deleted_at is null` rather than from the collection size.

**This whole procedure is for TOTAL collection loss only.** For partial divergence — the far likelier case, and what a Postgres restore produces — do not null every hash. `Engram.Workers.OrphanSweep` reconciles both directions against Qdrant's real point ids on its 05:00 UTC daily tick and flags only the notes that actually lost their points (#1576). Enqueue it on demand instead of waiting.

## DR scenarios

Each is one paragraph and links out to the canonical runbook. Don't restate rotation procedures here — they drift.

**AWS region down (us-east-1).** Single-region at launch — there is no failover. Wait for AWS recovery; post status to the public status page (#252) and hold. Multi-region failover is deliberately out of scope until traffic/SLO justify it.

**RDS Postgres data loss / corruption.** Restore from automated snapshot, or point-in-time to any moment within the 7-day window (RPO ≈ 4 min), to a new instance; then cut the app over by repointing `DATABASE_URL`. Drilled 2026-09-05: **7 min 34 s to a usable instance, schema byte-identical** — actuals and the gotchas that cost time are in the RDS section above. Restore from `engram-breakglass`; the operator identity is not authorized.

**A Postgres restore is not finished until Qdrant is reconciled.** Restoring rolls back the note data *and* the `embed_hash`/`dense_indexed_hash` bookkeeping about what was sent to Qdrant, together — so they stay mutually consistent while Qdrant does not. Every note re-indexed between the restore point and the failure has vectors under ids that no longer exist, and still reads as freshly indexed. Left alone those notes are silently unsearchable forever; `ReconcileEmbeddings` never notices, because it only ever compares two Postgres columns.

Enqueue `Engram.Workers.OrphanSweep` immediately after the cutover rather than waiting for its 05:00 UTC tick (#1576). It reconciles both directions against Qdrant's real point ids: strays get deleted, and notes whose points are gone get their index hashes nulled so `ReconcileEmbeddings` rebuilds exactly those. **Do not blind-rebuild the whole corpus for this** — the sweep identifies the diverged set, so recovery is proportional to the damage window, not the whole note count.

```elixir
Oban.insert!(Engram.Workers.OrphanSweep.new(%{}))
```

**If the log says `orphan_sweep aborting: missing-point ratio implies a bad authority`, read it carefully — after a restore it is probably wrong.** The sweep refuses to act when more than 10% of chunks look stranded, because that shape normally means Qdrant is unreachable or repointed rather than that the data drifted. A restore is the one case where a large real divergence is expected: a PITR restore at a ~4 min RPO stays well under the threshold, but a **snapshot** restore rolls back up to 24 h of writes and can legitimately cross it. Confirm Qdrant is healthy and reachable first, then re-enqueue with the override:

```elixir
Oban.insert!(Engram.Workers.OrphanSweep.new(%{"force" => true}))
```

Without that flag, the sweep aborts every tick and the notes are never repaired — silently, since an aborted pass flags nothing and otherwise looks like a clean one.

**S3 attachment loss / accidental delete.** Versioning is on — remove the delete marker (or restore the prior version) for the affected key; proven above. Bulk loss: re-list versions and restore. Recoverable for 30 days only; no cross-region replication at launch.

**Qdrant Cloud cluster lost or account compromised.** Rotate the Qdrant API key (`engram-infra/docs/context/qdrant-prod-cluster.md`), then restore the newest good Cloud backup into a new cluster and re-point TF (the restore route above). Fall back to the full rebuild only when no backup is usable. Search is keyword-only until the rebuild completes; reads and writes of note content are unaffected (Postgres is ground truth).

**Voyage AI key leaked.** Rotate via SOPS — see `engram-infra/docs/context/sops-pattern.md` (atomic env rotation). Embedding pauses until the new key propagates; existing vectors are unaffected.

**Paddle account suspended.** Service continues; billing/revenue paused; customer data unaffected (Paddle is Merchant of Record — revenue data lives in Paddle's dashboard, exportable there). No engram-side data action required.

**Key compromise.** Prod wraps DEKs with the AWS KMS CMK and has no master key; a suspected single-user DEK leak is the T3.7 per-user DEK rotation in `docs/context/encryption-operations.md`. On staging/self-host (Local provider), master-key compromise is the T3.5 rotation in the same doc. Note plaintext is never exposed by a re-wrap.

## Out of scope (launch-minimum)

Multi-region failover drills, cross-AZ HA testing, full simulation of non-RDS scenarios, and a Paddle data-export procedure are all deferred — see #255 for rationale. Drill RDS only; trust the existing rotation runbooks (linked above) for the rest.

**Re-drill when** the DB grows materially past 20 GB, the instance class changes, or multi-AZ is promoted — restore time scales with volume size and the recorded RTO stops being true.
