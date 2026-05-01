# Context Doc: Encryption-at-Rest Operations

_Last verified: 2026-04-30_

## Status
Notes-level encryption is shipped (Phase 1-6, PRs #37/#38/#43/#50). Attachments remain plaintext (Phase 7 pending — see `docs/encryption-toggle-followups.md`).

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
| Postgres `attachments` | `content`, `name` | ❌ plaintext (Phase 7 pending) |
| Tigris/S3 attachment bytes | binary blob | ❌ plaintext (Phase 7 pending) |

**Don't claim "encryption at rest" without that caveat.** Attachment-bearing vaults are not fully encrypted today — communicate this in support contexts.

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
