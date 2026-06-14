# Context Doc: Disaster Recovery & Backup Readiness

_Last verified: 2026-06-13 (launch-minimum, AWS prod)_

> **Why this exists:** "A backup that's never been restored isn't a backup." This is the launch-minimum DR runbook for engram prod (AWS account `751667630925`, region `us-east-1`). One paragraph per failure scenario; it **links** to the existing rotation runbooks rather than restating them. Tracks issue #255.

## Prod topology (data stores)

| Store | Identity | Backup mechanism | Verified state (2026-06-13) |
|-------|----------|------------------|------------------------------|
| **RDS Postgres** | `engram-prod` (PG 18.3, single-AZ) | Daily automated snapshots, 7-day retention, window 08:00–09:00 UTC | ✅ retention = 7d; latest snapshot `rds:engram-prod-2026-06-13-08-14` **available** |
| **S3 attachments** | `engram-saas-prod-attachments-751667630925` | Bucket versioning | ✅ versioning **Enabled** (read-verified); active delete→restore proof **pending data-plane creds** |
| **Qdrant Cloud** | managed free-tier cluster | Provider-managed snapshots | ⏳ retention **pending console confirm**; fallback = full reindex (see below) |

Single-AZ is intentional at launch (RPO/RTO acceptable for a low-customer-count launch; multi-AZ promoted post-launch when traffic/SLO justify it — explicitly out of scope here).

## Verified backup posture

- **RDS** — Automated snapshots ON, retention 7 days (meets the ≥7-day bar). RPO ≈ up to 24h between automated snapshots + 5-min transaction-log restore granularity (point-in-time recovery within the retention window). RTO: dominated by snapshot-restore-to-new-instance time (single-AZ, small DB → tens of minutes). **Restore drill (restore snapshot → throwaway instance → schema diff → record RPO/RTO actuals) is still outstanding — tracked as the remaining acceptance item on #255.**
- **S3 attachments** — Versioning Enabled, so overwrites and deletes are recoverable from version history. The delete-then-restore proof requires S3 data-plane perms (`s3:PutObject`/`s3:DeleteObject`), which the `engram-infra-operator` identity deliberately lacks (data plane is the ECS task role only). Run the proof from the task role or via a scoped, time-boxed IAM grant — **do not** broaden the operator policy.
- **Qdrant** — Vectors are reconstructable from Postgres ground truth at any time, so Qdrant loss is recoverable independent of Qdrant's own snapshots. Confirm managed snapshot retention in the Qdrant Cloud console; the belt-and-suspenders fallback is a full reindex (`mix engram.reindex`, planned in #173 — not yet built).

## DR scenarios

Each is one paragraph and links out to the canonical runbook. Don't restate rotation procedures here — they drift.

**AWS region down (us-east-1).** Single-region at launch — there is no failover. Wait for AWS recovery; post status to the public status page (#252) and hold. Multi-region failover is deliberately out of scope until traffic/SLO justify it.

**RDS Postgres data loss / corruption.** Restore from automated snapshot (or point-in-time within the 7-day window) to a new instance, then cut the app over by repointing `DATABASE_URL`. The restore drill that proves this end-to-end is the outstanding #255 item; once run, paste the RPO/RTO actuals into this doc.

**S3 attachment loss / accidental delete.** Versioning is on — recover the prior version (or remove the delete marker) for the affected key. Bulk loss: re-list versions and restore. No cross-region replication at launch.

**Qdrant Cloud account compromised or cluster lost.** Rotate the Qdrant API key, then rebuild the collection from Postgres via reindex (`mix engram.reindex`, #173). Search is degraded until reindex completes; reads/writes of note content are unaffected (Postgres is ground truth).

**Voyage AI key leaked.** Rotate via SOPS — see `engram-infra/docs/context/sops-pattern.md` (atomic env rotation). Embedding pauses until the new key propagates; existing vectors are unaffected.

**Paddle account suspended.** Service continues; billing/revenue paused; customer data unaffected (Paddle is Merchant of Record — revenue data lives in Paddle's dashboard, exportable there). No engram-side data action required.

**Encryption master key compromised.** Rotate the master key via the T3.5 procedure — see `docs/context/encryption-operations.md` (master-key rotation + BootCanary). Per-user DEKs are re-wrapped; note plaintext is never exposed.

## Out of scope (launch-minimum)

Multi-region failover drills, cross-AZ HA testing, full simulation of non-RDS scenarios, and a Paddle data-export procedure are all deferred — see #255 for rationale. Drill RDS only; trust the existing rotation runbooks (linked above) for the rest.

## Remaining acceptance (#255)

- [ ] RDS restore drill → throwaway instance → schema diff → record RPO/RTO actuals here
- [ ] S3 delete→restore proof (needs data-plane creds: task role or scoped grant)
- [ ] Qdrant snapshot retention confirmed in console + noted in the table above
- [ ] Cross-link from `engram-workspace/docs/context/launch-day-procedure.md` pre-flight row 10 + workspace `CLAUDE.md` (separate workspace-repo PR)
