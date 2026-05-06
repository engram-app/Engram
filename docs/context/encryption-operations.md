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
