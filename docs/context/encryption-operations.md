# Context Doc: Encryption-at-Rest Operations

_Last verified: 2026-10-07_

Operator runbooks for encryption at rest. Encryption is unconditional: every note, vault, attachment and Qdrant payload is encrypted under a per-user DEK; there is no per-vault toggle. Path/folder/tags/name are HMAC blind indexes plus encrypted display values. The only plaintext frontmatter columns are the dates `notes.fm_timestamp`/`fm_created` (kept plain for range queries); frontmatter `type` is encrypted with a `type_hmac` blind index, `description`/`resource` are encrypted display-only. DEK rotation rewraps all three and re-derives `type_hmac`.

**Which key wraps the DEKs depends on the deploy.** Prod uses AWS KMS (`KEY_PROVIDER=aws_kms`) and sets no `ENCRYPTION_MASTER_KEY` (engram-infra `main/envs/prod/ecs_secrets.tf`). Staging and self-host use the Local provider with `ENCRYPTION_MASTER_KEY`. So the master-key rotation and backup sections apply to staging/self-host only; per-user DEK rotation (T3.7) applies everywhere. KMS traps: `aws-kms-provider-integration.md`.

---

## Envelope formats (format 0 / format 1, #1872)

Every encrypted column is `ct_with_tag` plus a `nonce` field, produced by
`Engram.Crypto.Envelope` over the Rust engine (`Engram.Native.envelope_seal/4`,
`envelope_open/4`; AES-256-GCM from the `ring` crate, see `native-nifs.md`
"Envelope engine" for why). The nonce field's length is the format tag:

| Format | Nonce field | AAD to AES-GCM | Body (before the 16-byte tag) |
|---|---|---|---|
| 0 | 12 bytes | the caller's AAD, unchanged | the plaintext (byte-identical to `:crypto` AES-256-GCM) |
| 1 | `<<1, nonce::12>>` (13 bytes) | caller AAD `<>` `"\|f1"` | `<<codec, payload>>`, codec 0 = raw, 1 = zstd (level 3, checksum + content size on) |

- The `"|f1"` AAD suffix binds the format: a format-1 body cannot be replayed as
  format 0 (or the reverse) because the tag will not verify.
- Format 0 is the only format written today: `config :engram,
  :envelope_compression` defaults to `false` in every env. Flipping it on is a
  behaviour change that needs the follow-ups below first. Reading both formats
  always works.
- Empty plaintext is always format 0, so `has_content?/1` in revisions
  (`byte_size(ct) > tag_bytes()`) keeps its meaning.
- Anything that packs the nonce at a fixed offset stays format 0 forever
  (`KeyProvider.Local`'s wrap blob `<<version, alg, nonce::12, ct>>`); their AADs
  are not in the policy.
- Decode streams the zstd frame and never trusts the declared size, so a forged
  frame cannot force a huge allocation. Anything that fails to authenticate,
  decode or parse returns `:error`; a key that is not 32 bytes raises
  `FunctionClauseError` from `Envelope`'s guard (unchanged).

Compression policy, keyed by the AAD prefix `table <> <<0>> <> column <> <<0>>`
(`Crypto.aad_prefix/2`), only when `:envelope_compression` is on:

| Mode | Columns |
|---|---|
| `:zstd` | `notes.content`, `notes.crdt_state`, `vault_index_states.state`, `vault_index_update_log.update`, `note_revisions.content` |
| `:auto` (64 KB sample, skip if it saves under 10%) | `attachments.content` |
| `:none` | everything else |

`crdt_update_log` rows reuse the `notes.crdt_state` AAD and so follow it.

**Follow-ups before the flag is turned on (R1/R2).**

- R1, DEK rotation and rewrap: rotation decrypts and re-seals through the same
  engine, so it carries the format along. Verify a rotation on a mixed
  format-0/format-1 vault before enabling.
- R2, PR 3 work: `CrdtBloatSweep` size math and the `tag_bytes/0` doc assume
  `ct = plaintext + tag`, which is wrong for format 1 (the body is compressed and
  carries one codec byte). Fix both before any format-1 row exists, or the sweep
  will misreport bloat.
- Rollback: set the flag back to `false`. Format-1 rows already written stay
  readable; there is no downgrade path that rewrites them to format 0, and an
  older release without the engine cannot read them.

---

## Tier-3 / T3.5, Master-key rotation runbook (Local provider: staging, self-host)

The master key (`ENCRYPTION_MASTER_KEY`) wraps every user's per-user DEK. Rotation is the operator action of swapping the master key without losing access to existing wrapped DEKs. T3.5 added:

- `Engram.Crypto.MasterRotation.rotate_user/2` — per-user rewrap (idempotent).
- `Engram.Crypto.MasterRotation.rotate_all/2` — cursor-driven streaming over the user fleet.
- `Engram.Crypto.MasterRotation.enqueue_all/2` — Oban-driven equivalent for production.
- `mix engram.rotate_master_key --target-version N` — Mix wrapper (dev / staging).
- `Engram.Crypto.BootCanary` — boot-time current-key-only verify; raises on mismatch.
- M4 fallback gate — `_PREVIOUS` consulted only for users still below `ENCRYPTION_MASTER_KEY_VERSION`.

### Pre-rotation checklist

1. **Backup the current master key** (see backup section below).
2. **Generate new key**: `openssl rand 32 | base64`.
3. **Confirm rotation infra is deployed**: target backend image must have T3.5 (commit ≥ PR #78, version ≥ 0.5.35).
4. **Confirm the canary table is provisioned**: `SELECT count(*) FROM system_canaries`. Should be `≥ 1` after a single boot of T3.5-or-later.

### Rotation procedure

1. **Set rotation env vars** on running app:

   ```
   ENCRYPTION_MASTER_KEY=<NEW>                   # the new key
   ENCRYPTION_MASTER_KEY_PREVIOUS=<OLD>           # the prior key
   ENCRYPTION_MASTER_KEY_VERSION=<TARGET>         # bump (e.g. 1 → 2)
   BOOT_CANARY_ENABLED=false                      # bypass guard for the window
   ```

   Restart the app. Without `BOOT_CANARY_ENABLED=false`, boot would FAIL because the latest canary row is wrapped under `<OLD>` and current is now `<NEW>` (and `BootCanary.verify!/0` calls `unwrap_dek_no_fallback/2`, which refuses to consult `_PREVIOUS`). The env override skips `BootCanaryGuard` entirely so the app comes up.

   For SaaS the rotation env lives in SOPS+TF; the canonical wiring is `engram-infra/main/envs/staging-fastraid/env.tf` + `engram-infra/secrets/staging-fastraid.enc.yaml`. Stack the rotation env onto the same engram-infra PR that bumps the image so one tf-apply destroys+creates with both new image AND rotation env. See `engram-infra/docs/context/sops-pattern.md` § "Master-key rotation flow (T3.5)" for the PR sequence.

   M4 gate behavior: with VERSION bumped to N, every user at `dek_version < N` is rotation-eligible; `_PREVIOUS` rescues their reads while rotation is in-flight.

   > **Footgun:** if you set `MASTER_KEY` + `MASTER_KEY_PREVIOUS` but forget to bump `MASTER_KEY_VERSION`, every existing user read will fail with `{:error, :invalid_wrapping}` and telemetry `[:engram, :crypto, :previous_fallback_hit]` will report `outcome: :gated_by_dek_version`. That is the M4 gate working correctly — it refuses to silently fall back for "rotated" users. Bump VERSION and reads recover immediately.

2. **Run rotation**:

   - Dev / staging: `mix engram.rotate_master_key --target-version <TARGET>`.
   - Production: `Engram.Crypto.MasterRotation.enqueue_all(<TARGET>)` via release rpc; jobs land on the `:crypto_backfill` queue (concurrency 1) and survive node restarts.

3. **Verify completion**:

   ```sql
   SELECT MIN(dek_version), MAX(dek_version), count(*)
   FROM users
   WHERE encrypted_dek IS NOT NULL;
   ```

   `MIN(dek_version) >= TARGET` means rotation is complete.

4. **Rotate the canary**:

   ```
   /app/bin/engram rpc 'Engram.Crypto.MasterRotation.rotate_canary()'
   ```

   Restart the app — boot canary will now succeed. The next step removes `BOOT_CANARY_ENABLED=false` so the guard re-engages.

5. **Drop `_PREVIOUS` + boot-canary override**:

   ```
   ENCRYPTION_MASTER_KEY=<NEW>
   ENCRYPTION_MASTER_KEY_VERSION=<TARGET>
   # ENCRYPTION_MASTER_KEY_PREVIOUS unset
   # BOOT_CANARY_ENABLED unset (or any value other than literal "false")
   ```

   For SaaS this is a separate engram-infra PR removing `BOOT_CANARY_ENABLED` and `ENCRYPTION_MASTER_KEY_PREVIOUS` from `env.tf` + SOPS file, **keeping `ENCRYPTION_MASTER_KEY_VERSION=<TARGET>` permanent** (default falls back to "1"; removing while users are stamped at higher versions causes M4 fallback inconsistency).

   Restart. Boot canary verifies under NEW master + canary row. Container booting healthy = victory; the boot canary would have crashed it if anything is wrong. M4 telemetry `[:engram, :crypto, :previous_fallback_hit]` should be zero — if not, some user's wrap was missed. Investigate before proceeding.

### Telemetry to watch

- `[:engram, :crypto, :rotate, :user]` — per-user `:ok | :skipped | :failed`. Failures should be zero or single-digit (deleted user mid-flight).
- `[:engram, :crypto, :previous_fallback_hit]` — every fallback consultation. After step 5, this should be flat zero.
- `[:engram, :crypto, :boot_canary]` — `:ok` on every successful boot. `:failed` is fail-loud.

### Rollback (the master key is wrong)

If you discover post-step-5 that the new key is wrong (lost, corrupted, mistyped):

1. Re-add `ENCRYPTION_MASTER_KEY_PREVIOUS=<NEW>` and set `ENCRYPTION_MASTER_KEY=<OLD>`.
2. Decrement `ENCRYPTION_MASTER_KEY_VERSION` to the value it held before the rotation.
3. Boot canary fails (canary now wrapped under wrong-from-its-perspective key) — disable boot_canary_enabled.
4. Run rotate-down by manually resetting `users.dek_version` to the prior target via SQL, then rotate forward to that target. Current rotate-down ergonomics are minimal.

---

## Tier-3 / T3.5.6, Master-key backup procedure (Local provider)

> Prod has no master key (KMS wraps its DEKs). This section covers the staging key and any self-host operator's own key.

### What to back up

The master key is **the** secret. Loss = total ciphertext loss for every user (no per-user DEK is recoverable without it).

Sources of truth:

- `ENCRYPTION_MASTER_KEY` (current).
- `ENCRYPTION_MASTER_KEY_PREVIOUS` (during rotation windows).

### Where to back up

**Tier-3 launch baseline (today):**

1. **Primary:** staging's key is in the SOPS-encrypted engram-infra secrets for `staging-fastraid`. Owner: open-claw.
2. **Secondary:** sealed printout in a physical safe at owner's residence. Owner: open-claw.
3. **Off-site copy:** encrypted, stored in 1Password personal vault. Owner: open-claw.

**Tier-3 follow-up (post-launch):**

- Add at least one independent backup with a non-owner trustee (legal next-of-kin or a designated co-signatory).
- Add a quarterly restore drill schedule.

### When to rotate

- **Mandatory:** after any suspicion of master-key exposure (logs, crash dumps, env-var leak in screenshots, etc.).
- **Mandatory:** before significant operator transitions (handing off ops to a new owner).
- **Optional / opportunistic:** every 12 months as a cleanliness drill.

### Restore drill (quarterly)

1. On a non-prod laptop, decrypt the off-site copy.
2. Boot a fresh copy of the latest engram image with `ENCRYPTION_MASTER_KEY=<RESTORED>` against a recent snapshot of the database that key protects, in a dev compose stack.
3. Confirm `Engram.Crypto.BootCanary.verify!()` passes — i.e., the restored key matches what's in `system_canaries`.
4. List a few notes via the API to confirm content decrypts.
5. Tear down the test stack. Drill complete.

If the drill fails, surface it as a P0 immediately; the off-site copy is suspect.

### Owners + drill schedule

| Role | Person | Responsibility |
|---|---|---|
| Primary owner | open-claw | Holds + rotates the master key, runs drills |
| Drill scheduler | open-claw (until backup owner exists) | Runs quarterly drill, escalates failures |
| Backup trustee | _[unassigned — to be appointed before saas paying-customers]_ | Emergency decryption authority |


## T3.7.4 — DEK leak incident response runbook

A per-user DEK leak is a Critical-severity event. Until T3.7 shipped (2026-05-08), the only honest answer was "the user's data is permanently compromised — every ciphertext row was readable to whoever held the leaked key." T3.7 replaces that with a working rotation procedure: a single command that re-encrypts every note, vault, attachment, and Qdrant payload owned by one user under a fresh DEK, while the user is read+write locked (HTTP 503 + `Retry-After: 60`).

The orchestrator chooses the new dek_version internally (`current + 1`). Operators do not specify a target version. Re-running rotates again to a fresh version — do not re-enqueue without need.

### Detection signals

- An operator observes a DEK plaintext value outside the backend (logs, crash dump, exfiltrated heap snapshot).
- Telemetry `[:engram, :crypto, :previous_fallback_hit]` with `status: :failed` for a single `user_id` (suggests the user's wrapped DEK was tampered — investigate before rotating).
- A successful unauthorized decrypt on Qdrant payloads from an external IP (storage-layer leak indicator).

### Pre-rotation checks

1. Confirm no other rotation is in flight for this user:

       psql $DATABASE_URL -c "SELECT id, dek_rotation_locked_at FROM users WHERE id = :user_id;"

   If `dek_rotation_locked_at` is non-null and < 10 min ago, a rotation is already running. Wait for it to finish before re-issuing. Stale locks (> 10 min) are auto-takeover'd by `RotationLock.acquire/2`.

2. Capture the rollback reference:

       psql $DATABASE_URL -c "SELECT id, dek_version, encrypted_dek FROM users WHERE id = :user_id;"

   Store `dek_version` for verification post-rotation.

3. Notify the user (if appropriate) that their account will be unavailable for ~60s. Reads + writes return 503 during the window.

### Rotation command

Local / staging (Mix task — operator gets exit code, blocks until done):

    mix engram.rotate_user_dek --user-id <ID>

Production (release rpc — synchronous, fits short rotations < 1 min). Prod is AWS ECS Fargate, so shell in via ECS Exec rather than `docker exec`:

    aws ecs execute-command --cluster <cluster> --task <task-id> \
      --container engram --interactive \
      --command "/app/bin/engram rpc 'Engram.Crypto.UserDekRotation.rotate_user(<ID>)'"

    # (Staging on FastRaid: docker exec engram /app/bin/engram rpc "...")

Production (Oban worker — preferred for long rotations that must survive node restarts):

    Engram.Workers.RotateUserDek.new(%{"user_id" => <ID>}) |> Oban.insert()

Worker uniqueness on `[:user_id]` collapses duplicate enqueues to the same job — safe to enqueue from multiple operator scripts without coordinating.

### Expected duration

- 1k notes: ~10s
- 10k notes: ~60s
- 100k notes: not yet benchmarked. If > 1 min outage is unacceptable, prefer the Oban worker route and operate during a planned maintenance window.

### Telemetry to watch

- `[:engram, :crypto, :rotate, :dek]`, one event per rotation, status in metadata. A failed status means investigate immediately.
- `[:engram, :crypto, :rotate, :dek, :row_failed]`, a row that failed to re-encrypt mid-sweep.

### Verify completion

    psql $DATABASE_URL -c "SELECT id, dek_version, dek_rotation_locked_at FROM users WHERE id = :user_id;"

Both must hold:

- `dek_version` advanced by exactly 1 from the pre-rotation snapshot.
- `dek_rotation_locked_at` is NULL.

If `dek_version` did not advance OR `dek_rotation_locked_at` is still set, rotation failed mid-flight. Inspect Logger.error output (category `:crypto`) for the failing phase, fix the underlying cause, then re-run the same command. Resume is best-effort: the sweep loops use decrypt-as-discriminator (try old DEK, fall through to new DEK), so any rows already rotated by the failed run are tolerated on the retry; remaining rows finish under the new DEK.

### Rollback

DEK rotation has NO clean rollback once `users.encrypted_dek` is flipped (final phase of the orchestrator). Pre-flip rollback: re-acquire the lock, manually clear `attachments.dek_version_pending` and revert any partially-rotated rows from a backup. Post-flip rollback: not supported. Restore from a database snapshot taken before the rotation if absolutely required.

The lock-during-rotation contract, `RotationLockCheck` plug for REST routes plus `RotationGate` checks in the channel gate (`EngramWeb.ChannelGate`), CRDT persistence and Oban writers (`BackfillCrdtHead`), blocks all per-user write paths during the rotation window. Reads are also gated to avoid the brief sweep-progress window where rotated rows would decrypt-fail under the still-cached old DEK. The post-flip risks are operator error in the rotation command itself (catastrophic but defended by pre-flight checks above) and any new writer that accesses the user's DEK without going through the gate.

### Half-state recovery (after a mid-attachment crash)

If the rotation crashed mid-attachment (BEAM died between the S3 PUT and the second DB transaction in `sweep_attachments`), the user is left with:

- `users.dek_rotation_locked_at` non-null (intentional — operator must investigate).
- One or more `attachments.dek_version_pending` non-null (the half-rotated rows).
- S3 blobs for those attachments encrypted under a DEK that is permanently lost (the in-flight DEK_new from the dead BEAM's heap).

Stale-lock takeover (after 10 min) is REFUSED in this state — `acquire/1` returns `{:error, :half_state_pending}`, the worker discards `:half_state_pending`, the Mix task exits with code 5. This is intentional: a fresh rotation would generate a different DEK and corrupt the half-rotated S3 blobs irreversibly.

Recovery steps:

1. Identify the half-rotated attachments:

       SELECT id, vault_id, storage_key, dek_version, dek_version_pending FROM attachments
        WHERE user_id = :user_id AND dek_version_pending IS NOT NULL;

2. For each `storage_key`, restore the previous version from S3 versioning (the version BEFORE the failed PUT). The AWS S3 console exposes the version history.

3. Once all S3 blobs are restored, clear the pending column and the user lock in one transaction:

       BEGIN;
       UPDATE attachments SET dek_version_pending = NULL
         WHERE user_id = :user_id AND dek_version_pending IS NOT NULL;
       UPDATE users SET dek_rotation_locked_at = NULL WHERE id = :user_id;
       COMMIT;

4. Re-run the rotation. Since the S3 blobs are now back at the pre-rotation state and `dek_version` was never bumped on those rows, the sweep proceeds normally under a fresh DEK.

If S3 versioning is not available or the restore fails, the data is lost — the only recourse is to delete the affected attachment rows and notify the user. There is no way to recover the in-flight DEK from a dead BEAM heap.

---

## Content-hash MD5 to HMAC backfill (removed)

`content_hash` moved from MD5 to a per-user HMAC-SHA256 on 2026-05-06. The
one-time backfill (`Engram.ContentHash.Backfill`, `BackfillContentHashHmac`,
the `engram.content_hash_hmac` Mix task) was deleted after the 2026-10-06 prod
audit found zero legacy 32-char hashes. Read paths still treat a 32-char hash
as stale. A restore from a pre-2026-05-06 backup would need the backfill back
from git history (`git log --diff-filter=D -- lib/engram/content_hash/backfill.ex`).
