# Context Doc: Encryption-at-Rest Operations

_Last verified: 2026-05-05 (post-B.3)_

> **⚠ Most of this runbook is historical.** Phase B.3 (PR #71, 0.5.28) retired the vault decrypt path entirely — the `POST/DELETE /api/vaults/:id/decrypt` endpoints, `Engram.Workers.DecryptVault`, and the `Engram.Crypto.request_decrypt_vault/2` / `cancel_decrypt_vault/2` API are all deleted. Encryption is one-way; per-note read decryption happens transparently. The toggle/cooldown sections below describe the pre-B.3 world and are kept for historical context only.
>
> **Current operator surface (post-B.3):**
> - Every saas vault is encrypted at rest. Path/folder/tags/name plaintext columns dropped on saas in B.3.
> - `POST /api/vaults/:id/encrypt` still exists — it converts a non-encrypted vault to encrypted (one-way). New vaults default to non-encrypted; this is closing in B.4.
> - `GET /api/vaults/:id/encryption_progress` still works for monitoring an in-flight encrypt job.
> - Decrypt routes return 404 (route removed in B.3, no replacement).
> - To check vault state, query Postgres directly or use the engram MCP `list_vaults`.
>
> **Forward plan:** see `workspace/docs/encryption-tier-2-plan.md`. B.4 retires the `vault.encrypted` flag, drops `notes.content`/`title` plaintext columns, and removes the encrypt toggle entirely (every vault encrypted by default at create time).

## Status (historical — pre-B.3)

**Two parallel surfaces — different rules:**

- **Notes (Phase 1-6, PRs #37/#38/#43/#50):** per-user opt-in toggle, encryption-at-rest in Postgres + Qdrant payload. Toggle/cooldown semantics described below still apply. Will be retired under Tier 2 Phase E.
- **Attachments (Tier 2 Phase A complete, PRs #58→#62, 0.5.19):** **mandatory at-rest encryption** for every user, no toggle. Bytes live in S3-compatible storage only (MinIO local / Tigris prod). The legacy BYTEA `content` column was dropped in PR #62. `STORAGE_BACKEND=s3` is the only accepted value at boot.

The toggle described in this runbook governs **notes only**. Attachments encrypt unconditionally — no operator action needed.

### Phase A — Attachment encryption (PR #58, 0.5.15)

- New uploads encrypt before S3 put when `STORAGE_BACKEND=s3` is active.
- Legacy BYTEA reads continue to work unchanged (dual-flow `get_attachment`).
- `mix engram.backfill_bytea_to_s3` enqueues one Oban job per (user, vault) with legacy rows.
- Worker is idempotent and cursor-driven; rerun is safe.
- BYTEA column NOT yet dropped — happens in PR #62 after PR #61 cuts writes to S3-only.
- Telemetry events for encrypt/decrypt are deferred to PR #59 (Phase A reland keeps surface area minimal).
- See `docs/superpowers/plans/2026-05-02-encryption-attachments-reland.md` for the full reland plan + production runbook.

### A.4 — Cut writes to S3-only (PR #61, 0.5.18)

- `prepare_upload/6` no longer branches on adapter — single encrypted S3 write path.
- `STORAGE_BACKEND=database` is now a fatal misconfig: `runtime.exs` raises at boot.
- Boot default flipped from `database` → `s3`; legacy `Storage.Database` adapter remains for read-only access to pre-encryption BYTEA rows until A.5 retires it.
- Defense in depth: even if adapter somehow resolves to `Storage.Database`, `prepare_upload/6` returns `{:error, :writes_disabled}` rather than silently overwriting BYTEA with ciphertext (the 2026-05-02 corruption shape).
- BYTEA `content` column + `Storage.Database` adapter retire in PR #62 (A.5) once selfhost is verified at zero `WHERE encryption_version = 0 AND content IS NOT NULL` rows.

### A.5 — Drop BYTEA `content` column + retire `Storage.Database` (PR #62, 0.5.19)

- Migration `20260502093330_drop_attachment_bytea_content` drops the `content` column and the `attachments_legacy_plaintext_idx` partial index. **Irreversible** — `down/0` raises.
- Pre-merge probe (2026-05-02): saas had 105 attachments, 0 legacy; selfhost had 0 attachments. Zero rows lost.
- Schema: `Engram.Attachments.Attachment.content` is now a `:virtual` field — set in-memory by `decrypt/3` only.
- Read path (`get_attachment/3`) collapsed to a single S3 fetch + decrypt; the `content non-nil` short-circuit is gone.
- `Engram.Storage.Database` module deleted. `Engram.Workers.BackfillByteaToS3` worker + `mix engram.backfill_bytea_to_s3` task deleted (no callers left).
- `runtime.exs` only accepts `STORAGE_BACKEND=s3`; any other value (including `database`) raises at boot.
- Validations now require `encryption_version == 1` and `content_nonce` on every row. The dual-version branch in `decrypt_if_needed` is gone — version 0 is unrepresentable.

## What This Is
Operator runbook for encryption toggling, per-user cooldown, and incident triage. Companion to the architecture spec at `docs/superpowers/specs/2026-04-07-encryption-at-rest-design.md`.

## Per-User Toggle Cooldown

Users can encrypt/decrypt their vaults via the plugin (`POST /api/vaults/:id/encrypt`, `POST /api/vaults/:id/decrypt`). To prevent abusive flapping, each user has an independent `users.encryption_toggle_cooldown_days INTEGER NULL` column.

| Value | Behavior |
|-------|----------|
| `NULL` (default) | No cooldown — user can re-toggle immediately. This is the self-hosted default. |
| `0` | Treated identically to `NULL` (no cooldown). |
| `N > 0` | User must wait `N` days between encrypt and decrypt toggles. Server returns `429` with an ISO-8601 `retry_after` body when the gate fires. |

The plugin reads the effective `cooldown_days` from the vault JSON (`/api/vaults`) so it can surface "next toggle in N days" without a probe POST.

### Setting the cooldown

```bash
# In a release shell on the FastRaid container
docker exec -it engram bin/engram remote
iex> Engram.Accounts.set_encryption_toggle_cooldown_days(Engram.Accounts.get_user!(<id>), 7)

# OR from a dev shell with .env.elixir loaded
mix engram.set_cooldown <user_id> <days|null>
```

The Mix task accepts `null`, `none`, or `NULL` to clear the column. Negative values are rejected at the function-clause level — there is no `0`-vs-`NULL` distinction at the Crypto layer (both bypass the cooldown predicate).

Hosted-mode default policy (until Stripe webhook wiring lands per follow-up #10): the operator sets cooldown manually per user, typically by tier (Free=1 day, Pro=NULL).

## Toggle Flow & State Machine

`vaults.encryption_status` transitions:

```
none ─encrypt─▶ encrypting ─backfill done─▶ encrypted
                                                │
                                          decrypt-request
                                                ▼
                                          decrypt_pending  (24h cancel window)
                                                │
                                       cancel│   │auto after 24h
                                                ▼
                                          decrypting ─backfill done─▶ none
```

`vaults.last_toggle_at` is set on every state-changing call (encrypt, decrypt, cancel). The cooldown predicate compares `last_toggle_at` against the user's `encryption_toggle_cooldown_days`.

The 24-hour `decrypt_pending` window is **cancellable**: the user can `DELETE /api/vaults/:id/decrypt` to abort, which returns the vault to `encrypted` without consuming a cooldown cycle.

## What's Encrypted

| Surface | Field(s) | Status |
|---------|----------|--------|
| Postgres `notes` | `content`, `title`, `tags` | ✅ ciphertext when vault is encrypted |
| Qdrant payload | `text`, `title`, `heading_path` | ✅ ciphertext (Jina/Voyage never sees plaintext for encrypted vaults) |
| Postgres `attachments` | `content` column | ✅ **dropped entirely** (PR #62) — bytes live in S3 only |
| Postgres `attachments` | `name` / `path` | ❌ plaintext (Tier 2 Phase B pending) |
| Tigris/S3 attachment bytes | binary blob | ✅ ciphertext (mandatory, AES-GCM via per-user DEK; PR #58→#62) |

**Remaining plaintext surfaces under Tier 2:** attachment paths/names, note source paths, folder names, tags. These get HMAC fingerprints + encrypted display values in Phase B. Until Phase B ships, communicate this honestly in support contexts — bytes are sealed, but field names that index them are not.

## Triage Recipes

### A user reports stuck encryption

Check the vault row:
```sql
SELECT id, encryption_status, encrypted, last_toggle_at, decrypt_requested_at
FROM vaults WHERE id = <vault_id>;
```

If status is `encrypting` or `decrypting`, look at the Oban queue:
```sql
SELECT id, worker, args, state, attempt, errors
FROM oban_jobs
WHERE worker LIKE '%EncryptVault%' OR worker LIKE '%DecryptVault%'
ORDER BY id DESC LIMIT 20;
```

A discarded job means retries exhausted — read `errors[*].error` to diagnose. The worker is **idempotent on retry** as of PR #50: it filters out notes whose ciphertext is already populated, so re-enqueueing is safe.

### A user is hitting 429 unexpectedly

Check the user's cooldown:
```sql
SELECT id, email, encryption_toggle_cooldown_days FROM users WHERE id = <user_id>;
```

The 429 body's `retry_after` is `last_toggle_at + cooldown_days`. If cooldown_days is set unintentionally (e.g., during a tier downgrade), clear it via the Mix task.

### A user asks "is my data encrypted?"

Confirm both:
1. `vaults.encryption_status = 'encrypted'` for their active vault.
2. They have **no attachments** in that vault, OR they understand attachments are still plaintext.

If they have attachments and need full coverage, Phase 7 isn't shipped yet — add them to a waitlist and flag in `docs/encryption-toggle-followups.md`.

## References

- Architecture spec: `docs/superpowers/specs/2026-04-07-encryption-at-rest-design.md`
- Phase 6 implementation: PR #43 (toggle endpoints + backfill workers)
- Cooldown implementation: PR #50 (per-user cooldown), PR #51 (mix task)
- Plugin UI: PR #24 (encryption tab + status badge), PR #25 (error handling + persistent status row)
- Follow-up tracking: `docs/encryption-toggle-followups.md`

---

## Tier-3 / T3.5 — Master-key rotation runbook

_Added 2026-05-08 with PR #78 (T3.5)._

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

1. **Set both env vars + bump version** on running app:

   ```
   ENCRYPTION_MASTER_KEY=<NEW>                  # the new key
   ENCRYPTION_MASTER_KEY_PREVIOUS=<OLD>          # the prior key
   ENCRYPTION_MASTER_KEY_VERSION=<TARGET>        # bump (e.g. 1 → 2)
   ```

   Restart the app. Boot canary will FAIL because the latest canary row is wrapped under `<OLD>` and current is now `<NEW>`. **This is expected before step 2 runs** — the canary is the leading edge.

   To bring up the app during rotation, set `:engram, :boot_canary_enabled` to `false` (env override) for the duration. Re-enable as soon as step 4 completes.

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

   Restart the app — boot canary will now succeed. Re-enable boot_canary_enabled if you disabled it.

5. **Drop `_PREVIOUS`**:

   ```
   ENCRYPTION_MASTER_KEY=<NEW>
   # ENCRYPTION_MASTER_KEY_PREVIOUS unset
   ENCRYPTION_MASTER_KEY_VERSION=<TARGET>
   ```

   Restart. Boot canary verifies. M4 telemetry `[:engram, :crypto, :previous_fallback_hit]` should be zero — if not, some user's wrap was missed. Investigate before proceeding.

### Telemetry to watch

- `[:engram, :crypto, :rotate, :user]` — per-user `:ok | :skipped | :failed`. Failures should be zero or single-digit (deleted user mid-flight).
- `[:engram, :crypto, :previous_fallback_hit]` — every fallback consultation. After step 5, this should be flat zero.
- `[:engram, :crypto, :boot_canary]` — `:ok` on every successful boot. `:failed` is fail-loud.

### Rollback (the master key is wrong)

If you discover post-step-5 that the new key is wrong (lost, corrupted, mistyped):

1. Re-add `ENCRYPTION_MASTER_KEY_PREVIOUS=<NEW>` and set `ENCRYPTION_MASTER_KEY=<OLD>`.
2. Decrement `ENCRYPTION_MASTER_KEY_VERSION` to the value it held before the rotation.
3. Boot canary fails (canary now wrapped under wrong-from-its-perspective key) — disable boot_canary_enabled.
4. Run rotate-down by manually resetting `users.dek_version` to the prior target via SQL, then rotate forward to that target. Current rotate-down ergonomics are minimal — see Open Questions in `workspace/docs/encryption-tier-3-audit.md`.

---

## Tier-3 / T3.5.6 — Master-key backup procedure

_Added 2026-05-08 with PR #78 (T3.5)._

> **Selfhost reality check:** today, we have one paying environment (selfhost on FastRaid) and zero managed-key-by-customer instances. The "named owners" convention below applies primarily to the saas instance; selfhost users carry their own backup obligation, which is captured in product-level UX (out of scope here).

### What to back up

The master key is **the** secret. Loss = total ciphertext loss for every user (no per-user DEK is recoverable without it).

Sources of truth:

- `ENCRYPTION_MASTER_KEY` (current).
- `ENCRYPTION_MASTER_KEY_PREVIOUS` (during rotation windows).

### Where to back up

**Tier-3 launch baseline (today):**

1. **Primary:** the value lives in the FastRaid Unraid template's runtime ENV. SSH access required. Owner: open-claw.
2. **Secondary:** sealed printout in a physical safe at owner's residence. Owner: open-claw.
3. **Off-site copy:** encrypted, stored in 1Password personal vault. Owner: open-claw.

**Tier-3 follow-up (post-launch):**

- Add at least one independent backup with a non-owner trustee (legal next-of-kin or a designated co-signatory).
- Add a quarterly restore drill schedule (next drill: **2026-08-08**).

### When to rotate

- **Mandatory:** after any suspicion of master-key exposure (logs, crash dumps, env-var leak in screenshots, etc.).
- **Mandatory:** before significant operator transitions (handing off ops to a new owner).
- **Optional / opportunistic:** every 12 months as a cleanliness drill.

### Restore drill (quarterly)

1. On a non-prod laptop, decrypt the off-site copy.
2. Boot a fresh copy of the latest engram image with `ENCRYPTION_MASTER_KEY=<RESTORED>` against a recent prod database snapshot in a dev compose stack.
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

Next drill: **2026-08-08**. Track in `~/Calendar` or equivalent.

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

Production (release rpc — synchronous, fits short rotations < 1 min):

    docker exec engram-saas /app/bin/engram rpc \
      "Engram.Crypto.UserDekRotation.rotate_user(<ID>)"

Production (Oban worker — preferred for long rotations that must survive node restarts):

    Engram.Workers.RotateUserDek.new(%{"user_id" => <ID>}) |> Oban.insert()

Worker uniqueness on `[:user_id]` collapses duplicate enqueues to the same job — safe to enqueue from multiple operator scripts without coordinating.

### Expected duration

- 1k notes: ~10s
- 10k notes: ~60s
- 100k notes: not yet benchmarked. If > 1 min outage is unacceptable, prefer the Oban worker route and operate during a planned maintenance window.

### Telemetry to watch

- `engram.crypto.rotate.dek.count{status="ok"}` ≥ 1 — rotation completed.
- `engram.crypto.rotate.dek.count{status="failed"}` — investigate immediately. Reason label in event metadata.
- `engram.crypto.rotate.dek.duration_us` — verify within the expected band for note count.

### Verify completion

    psql $DATABASE_URL -c "SELECT id, dek_version, dek_rotation_locked_at FROM users WHERE id = :user_id;"

Both must hold:

- `dek_version` advanced by exactly 1 from the pre-rotation snapshot.
- `dek_rotation_locked_at` is NULL.

If `dek_version` did not advance OR `dek_rotation_locked_at` is still set, rotation failed mid-flight. Inspect Logger.error output (category `:crypto_rotation`) for the failing phase, fix the underlying cause, then re-run the same command. Resume is best-effort: the sweep loops use decrypt-as-discriminator (try old DEK, fall through to new DEK), so any rows already rotated by the failed run are tolerated on the retry; remaining rows finish under the new DEK.

### Rollback

DEK rotation has NO clean rollback once `users.encrypted_dek` is flipped (final phase of the orchestrator). Pre-flip rollback: re-acquire the lock, manually clear `attachments.dek_version_pending` and revert any partially-rotated rows from a backup. Post-flip rollback: not supported. Restore from a database snapshot taken before the rotation if absolutely required.

The lock-during-rotation contract — `RotationLockCheck` plug for REST routes plus `RotationGate` checks in Phoenix channels (`SyncChannel`) and Oban writers (`EmbedNote`, `BackfillContentHashHmac`) — blocks all per-user write paths during the rotation window. Reads are also gated to avoid the brief sweep-progress window where rotated rows would decrypt-fail under the still-cached old DEK. The post-flip risks are operator error in the rotation command itself (catastrophic but defended by pre-flight checks above) and any new writer that accesses the user's DEK without going through the gate.

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

2. For each `storage_key`, restore the previous version from S3 versioning (the version BEFORE the failed PUT). The Tigris/S3 admin UI exposes the version history.

3. Once all S3 blobs are restored, clear the pending column and the user lock in one transaction:

       BEGIN;
       UPDATE attachments SET dek_version_pending = NULL
         WHERE user_id = :user_id AND dek_version_pending IS NOT NULL;
       UPDATE users SET dek_rotation_locked_at = NULL WHERE id = :user_id;
       COMMIT;

4. Re-run the rotation. Since the S3 blobs are now back at the pre-rotation state and `dek_version` was never bumped on those rows, the sweep proceeds normally under a fresh DEK.

If S3 versioning is not available or the restore fails, the data is lost — the only recourse is to delete the affected attachment rows and notify the user. There is no way to recover the in-flight DEK from a dead BEAM heap.
