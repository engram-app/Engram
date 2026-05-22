# AWS KMS Phase 3 — Provider Migration Design

> **Status:** Design, pending implementation plan.
> **Predecessors:** PR #110 (Phase 1 — provider behaviour + AwsKms impl + conformance), PR #112 (Phase 2 — BootCanary polymorphism + KMS telemetry).
> **Successors:** Phase 4 (Fly secrets + IAM cutover runbook), Terraform templates (separate spec).

## Goal

Ship a per-user, blob-tag-discriminated migration path so engram-saas can flip `KEY_PROVIDER=local` → `aws_kms` without downtime, with a symmetric rollback. engram-selfhost stays Local forever.

## Non-Goals

- Per-user opt-in (single fleet-wide flag).
- Per-tier or per-vault provider selection.
- Schema changes (`users.encrypted_dek` + `users.key_provider` columns already exist).
- BootCanary or telemetry plumbing (Phase 2 already shipped).
- AWS account / IAM / KMS CMK provisioning (Terraform spec covers this).
- Production cutover runbook (Phase 4 spec covers this).

## Key Insight

Switching providers only rewraps the wrapped DEK blob. The underlying AES-GCM ciphertext rows (notes, attachments, qdrant payloads) are bound to the *plaintext* DEK, which is preserved across rewrap. One row update per user, no row-scan of tenant data. Migration cost is ~10× cheaper than T3.5 master rotation or T3.7 DEK rotation.

## Architecture

```
                  ┌──────────────────────────────────────┐
KEY_PROVIDER=aws_kms                                     │
                  │                                      │
                  ▼                                      │
       Resolver.provider() ──► used by:                  │
                  ├── ensure_user_dek/1 (new users)      │
                  └── ProviderMigration (wrap target)    │
                                                         │
        get_dek/1 ─► KeyProvider.identify_from_blob/1 ──►│
                     (0xAA → AwsKms, 0x01/0x02 → Local)  │
                     unwrap dispatched by blob tag,      │
                     NOT by Resolver.provider/0          │
                                                         │
        If blob_provider ≠ Resolver.provider():          │
          fire-and-forget enqueue MigrateUserProvider ───┘
```

Read path is provider-agnostic. Write path follows `KEY_PROVIDER`. Mixed state safe by construction during entire backfill window.

Forward (Local→KMS) and reverse (KMS→Local) share the same worker — `--target` arg flips direction. Rollback is symmetric, no extra code path.

## Components

### New files

| File | Purpose |
|---|---|
| `lib/engram/crypto/provider_migration.ex` | Public API: `migrate_user/2`, `migrate_all/2`, `enqueue_all/2`. Structural fork of `MasterRotation` (`lib/engram/crypto/master_rotation.ex`). |
| `lib/engram/workers/migrate_user_provider.ex` | Oban worker. Queue `:crypto_backfill`. Uniqueness `[:user_id, :target_provider]`. |
| `lib/mix/tasks/engram.migrate_provider.ex` | Ops entry point. Args: `--target aws_kms|local`, `--enqueue`, `--status`. Exit codes mirror `engram.rotate_master_key`. |
| `test/engram/crypto/provider_migration_test.exs` | Unit tests for `ProviderMigration` API. |
| `test/engram/workers/migrate_user_provider_test.exs` | Worker behaviour, retry vs discard classification. |
| `test/mix/tasks/engram.migrate_provider_test.exs` | Mix task arg parsing, exit codes, `--status` output. |

### Modified files

| File | Change |
|---|---|
| `lib/engram/crypto.ex` (`get_dek/1`, ~line 175-201) | Replace `provider = Resolver.provider_for(user_id)` with `{:ok, provider} = KeyProvider.identify_from_blob(blob)` for the unwrap dispatch. After successful unwrap, if `provider != Resolver.provider()`, enqueue `MigrateUserProvider` async (fire-and-forget; reads never block on rewrap). |
| `test/engram/crypto_test.exs` | Add dual-read tests covering all four `(blob_provider × configured_provider)` quadrants. |
| `test/engram/crypto/provider_conformance_test.exs` | Add cross-provider conformance: `wrap_with(A) → identify_from_blob → unwrap_with(B)` asserts `A == B`. |
| `test/engram_web/telemetry_test.exs` | Pin `[:engram, :crypto, :migrate_provider, :user]` handler registration. |

### Unchanged

- `KeyProvider` behaviour (Phase 1+2 callbacks sufficient).
- `BootCanary` / `BootCanaryGuard` (Phase 2 already polymorphic).
- `MasterRotation`, `UserDekRotation`, `AadRebind` (work transparently against either provider via `rotate_wrapping/2` / `unwrap_dek/2`).
- `users` schema, migrations.
- `ensure_user_dek/1` — first-write provisioning already uses `Resolver.provider/0` (`lib/engram/crypto.ex:136`).

## Data Flow — Forward Cutover (Local→KMS, engram-saas)

1. Ops sets Fly secrets: `KEY_PROVIDER=aws_kms`, `AWS_KMS_KEY_ID`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`. Deploy.
2. `BootCanaryGuard` invokes `KeyProvider.AwsKms.boot_check/0` → AWS `DescribeKey` ping. Fails the boot fast on IAM / ARN / region misconfig. (Phase 2.)
3. New users from this moment provisioned via KMS (`ensure_user_dek/1` → `Resolver.provider()` returns `AwsKms`).
4. Existing users still have Local-wrapped blobs. Their first read post-cutover:
   - `get_dek/1` → `identify_from_blob(blob)` → `Local` → unwrap succeeds → DekCache fills.
   - Provider mismatch detected → `MigrateUserProvider` enqueued async with `target_provider: "aws_kms"`. Zero added latency on the read.
5. Ops drives the backfill: `mix engram.migrate_provider --target aws_kms --enqueue`. Inserts one Oban job per user with `key_provider = "local"`.
6. Each worker job, per user:
   - `Repo.transaction` opens.
   - `SELECT ... FOR UPDATE` on `users` row.
   - `source_provider = KeyProvider.identify_from_blob(locked.encrypted_dek)`.
   - `{:ok, dek} = source_provider.unwrap_dek(blob, ctx)`.
   - `{:ok, new_blob} = target_provider.wrap_dek(dek, ctx)`.
   - `Accounts.update_user_encryption(locked, %{encrypted_dek: new_blob, key_provider: "aws_kms", dek_version: Config.master_key_version()})`.
   - Commit.
   - `DekCache.put(user_id, dek)` *after* commit (rolled-back txn must not poison cache — matches `ensure_user_dek/1` invariant from T3.1).
7. Operator monitors `[:engram, :crypto, :migrate_provider, :user]` telemetry + `SELECT key_provider, COUNT(*) FROM users GROUP BY 1`. Backfill done when `local` count = 0.

## Data Flow — Reverse Cutover (KMS→Local, rollback)

1. Flip `KEY_PROVIDER=local`. Redeploy. New writes immediately revert to Local.
2. Reads remain dual-routed: KMS blobs still unwrap via `KeyProvider.AwsKms` as long as AWS creds + IAM remain valid.
3. Run `mix engram.migrate_provider --target local --enqueue`. Same worker, target flips. KMS→Local rewraps.
4. Once `key_provider = "aws_kms"` count = 0, drop AWS secrets from Fly.

## Error Handling

Per-user failure classes mirror `MasterRotation.classify_reason/1`:

| Reason | Source | Worker behavior | Logging |
|---|---|---|---|
| `:kms_throttled` | KMS ThrottlingException | `{:error, reason}` → Oban retry w/ backoff | Telemetry only |
| `:kms_access_denied` | IAM denies Encrypt/Decrypt | `{:error, reason}` → retry | Logger.error + telemetry |
| `:invalid_wrapping` | EncryptionContext mismatch | `{:error, reason}` → retry (operator may need to investigate) | Logger.error + telemetry |
| `:kms_key_not_found` | CMK deleted/disabled | `{:error, reason}` → retry | Logger.error + telemetry |
| `:malformed_wrapped_blob` | Source blob format unexpected | `{:discard, reason}` (no infinite retry on data corruption) | Logger.error + telemetry |
| `{:not_found, uid}` | User row gone mid-flight | `:ok` (skip silently — user was deleted) | None |

**Atomicity:** rewrap executes entirely inside `Repo.transaction` with `SELECT ... FOR UPDATE`. If `target_provider.wrap_dek` fails after `source_provider.unwrap_dek` succeeds, the txn rolls back and `users.encrypted_dek` is untouched.

**Plaintext DEK hygiene:** `migrate_user/2` calls the same `mark_sensitive/0` primitive (process flag `:sensitive`) used by `Crypto.get_dek/1`. DEK plaintext lives only on the worker process stack during the txn; goes out of scope at txn close. Excluded from any future crash dump.

**Telemetry / log fan-out matches T3-audit H4 pattern (PR #81):** every failure emits both `Logger.error(reason_label=…)` AND `[:engram, :crypto, :migrate_provider, :user]` with `status: :failed, reason_label, provider: <target>`.

## Operator Tooling

```bash
# Sync drain (dev / staging only — blocks until done):
mix engram.migrate_provider --target aws_kms

# Production-friendly Oban enqueue (default for ops):
mix engram.migrate_provider --target aws_kms --enqueue

# Reverse rollback:
mix engram.migrate_provider --target local --enqueue

# Status:
mix engram.migrate_provider --status
# => %{aws_kms: 1240, local: 17, total: 1257}
# => Pending jobs in :crypto_backfill: 17
```

Exit codes:
- `0` — all users at target (or fleet empty).
- `1` — partial: at least one `:failed` outcome.
- `2` — misconfig (unknown `--target`, missing AWS env when target=aws_kms, etc.).

## Invariants

1. **`dek_version` stamp:** ProviderMigration writes `users.dek_version = Engram.Crypto.Config.master_key_version()` at rewrap time. A subsequent `MasterRotation` pass correctly skips just-migrated users (their `dek_version` already matches current master).
2. **Cache safety:** `DekCache.put/2` only after txn commits. Rolled-back txn never poisons cache.
3. **Idempotence:** `migrate_user/2` on a user already at target returns `:skipped`, no provider calls made. Mix task may be re-run safely.
4. **Dedup:** Oban uniqueness `[:user_id, :target_provider]` collapses duplicate enqueues from both backfill and lazy paths.
5. **Read-write split:** reads use `identify_from_blob/1`. Writes use `Resolver.provider/0`. Steady state: both agree. Migration window: they diverge per-user until backfill drains.

## Testing

### Unit (`provider_migration_test.exs`)

| Test | What it pins |
|---|---|
| `migrate_user/2 Local→KMS happy path` | Mox `AwsKmsMock.encrypt/2` deterministic ct → blob leading byte = `0xAA`, `key_provider = "aws_kms"`, `dek_version = master_key_version()`. DekCache populated with original plaintext DEK (round-trip identity). |
| `migrate_user/2 KMS→Local reverse` | Same as above, target = `:local`, blob leading byte = `0x01`/`0x02`. |
| `idempotent skip` | Second `migrate_user(uid, :aws_kms)` on already-KMS user returns `:skipped`, zero provider calls. |
| `concurrent rewrap race` | 4 parallel `migrate_user/2` calls for same user (`Task.async_stream`). Assert exactly one rewrap, three `:skipped`. Mirrors PR #74 race test. |
| `KMS failure modes` | Mox returns `{:error, :access_denied}` / `:throttled` / `:context_mismatch` → txn rolls back, `users.encrypted_dek` unchanged, telemetry emits `status: :failed, reason_label` per class. |
| `malformed source blob` | User row with junk blob → `{:error, :malformed_wrapped_blob}`, no destructive write. |
| `not-found user` | User deleted mid-flight → `:ok` (silent skip). |
| `dek_version stamp` | After Local→KMS, `users.dek_version == Config.master_key_version()`. |

### Worker (`migrate_user_provider_test.exs`)

- `perform/1` happy path delegates to `ProviderMigration.migrate_user/2`.
- `:kms_throttled` / `:kms_access_denied` → `{:error, ...}` (Oban retries).
- `:malformed_wrapped_blob` → `{:discard, ...}` (terminal, no infinite retry).
- Uniqueness `[:user_id, :target_provider]` rejects duplicate insert.

### Mix task (`engram.migrate_provider_test.exs`)

- `--target aws_kms` sync drain returns `%{ok: N, skipped: M, failed: K}`.
- `--target aws_kms --enqueue` inserts Oban jobs without performing rewraps.
- `--status` prints provider breakdown to stdout.
- Exit codes per scenario.

### `get_dek/1` dual-read (`crypto_test.exs`)

Four quadrant cases:
- Local blob + `KEY_PROVIDER=local` → read succeeds, no enqueue.
- KMS blob + `KEY_PROVIDER=aws_kms` → read succeeds, no enqueue.
- Local blob + `KEY_PROVIDER=aws_kms` → read succeeds via `identify_from_blob` Local dispatch, `MigrateUserProvider` job enqueued exactly once per Oban dedup window.
- KMS blob + `KEY_PROVIDER=local` → read succeeds via `identify_from_blob` KMS dispatch, reverse `MigrateUserProvider` job enqueued (rollback support).

### Conformance (`provider_conformance_test.exs`)

Add cross-provider parametrised case: for each `(source, target)` ∈ `{Local, AwsKms}²`, `wrap_with(source) → identify_from_blob → unwrap_with(identified)` round-trips identity (validates that `identify_from_blob/1` agrees with the producing provider for all blob shapes).

### Telemetry (`telemetry_test.exs`)

Pin `[:engram, :crypto, :migrate_provider, :user]` handler registration in `EngramWeb.Telemetry`. Measurements: `%{duration_us, count: 1}`. Metadata: `%{user_id, target_provider, status: :ok | :skipped | :failed, reason_label?}`.

## Out of Scope (Phase 4 / Terraform specs)

- Fly secrets provisioning sequence + verify steps.
- IAM policy YAML (with `kms:EncryptionContext:purpose = "dek_wrap"` `StringEquals` condition).
- Terraform module: AWS account / KMS CMK / IAM role + policy / variables for SaaS vs self-host.
- engram-selfhost guard (`KEY_PROVIDER=aws_kms` should be unsupported on the self-host image — Phase 4 to gate at boot).
- Production runbook (pre-flight checks, drain monitoring, abort criteria).
