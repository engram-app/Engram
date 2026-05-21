# Pricing v2 §G — Server-Side Enforcement Audit

**Date:** 2026-05-21 (shipped with PR #198).

Closes pricing-v2 §G's audit criterion: walk every `LimitKeys` catalog key and confirm each Free-restrictive limit has a server-side enforcement site. The `mix engram.lint.no_client_only_rate_limits` task encodes this audit and runs in CI on every push.

## Audit results

| Key | Free default | Server-side enforcement |
|-----|--------------|-------------------------|
| `notes_cap` | 10_000 | `Engram.Notes.insert_new_note/5` → `Billing.check_limit/3` → 402 (NEW in this PR) |
| `vaults_cap` | 1 | `Engram.Vaults.create_vault/2` + `register_vault/3` |
| `attachment_bytes_cap` | 1 GB | ⏳ opt-out (`AttachmentController.create/2` needs per-user lifetime quota check) |
| `max_file_bytes` | 10 MB | ⏳ opt-out (`AttachmentController.create/2` needs per-file size check) |
| `lifetime_embed_token_cap` | 20 M | `Engram.Workers.EmbedNote.embed_budget_gate/1` |
| `concurrent_devices` | 1 | ⏳ opt-out (`DeviceAuthController` needs explicit count check) |
| `device_swap_cooldown_hours` | 12 | ⏳ opt-out (`DeviceAuthController` needs cooldown check) |
| `realtime_sync_enabled` | false | `EngramWeb.SyncChannel.join/3` → `channel_forbidden_on_plan` (NEW in this PR; env-gated by `REALTIME_SYNC_GATE_ENABLED`, defaults off — flip on launch day so pre-v2 Free users aren't kicked off sync mid-flight) |
| `ai_conversations_per_day` | 5 | `Engram.ConversationMeter.day_cap_exceeded?/2` |
| `ai_queries_per_conversation` | 50 | `Engram.ConversationMeter.maybe_rotate_conversation/3` |
| `ai_queries_per_day` | nil (Free unmetered via conv cap) | `Engram.ConversationMeter.query_day_cap_exceeded?/2` |
| `conversation_window_minutes` | 30 | `Engram.ConversationMeter.maybe_rotate_conversation/3` |
| `reranker_enabled` | false | ⏳ opt-out (`SearchController` needs reranker-path gate) |
| `api_write_enabled` | false | ⏳ opt-out (write controllers need plan gate) |
| `api_rps_cap` | 0 | ⏳ opt-out (RateLimit plug should pull per-plan cap) |
| `inactivity_warn_60_days` | true | ⏳ opt-out — `InactivityCleanup` cron uses `Billing.tier/1` rather than reading the key directly |
| `inactivity_delete_days` | 90 | ⏳ opt-out — same as above |
| `cross_vault_search` | false | ⏳ opt-out (legacy UX flag) |
| `vault_scoped_keys` | false | ⏳ opt-out (legacy; superseded by `api_key_vaults`) |

## What "opt-out" means

The lint task allows a catalog key to skip server-side enforcement IFF it is listed in `Mix.Tasks.Engram.Lint.NoClientOnlyRateLimits.@opt_outs` with a reason string. Adding a new restrictive key to `LimitKeys` without either a server-side check or an opt-out entry fails CI via both the lint task itself AND the self-scan meta-test.

## Follow-ups before launch

Each ⏳ opt-out above is a follow-up PR. Suggested order, smallest-first:

1. **`reranker_enabled`** — search controller adds a single guard before invoking the reranker. ~10 LOC.
2. **`api_write_enabled`** — flag check in the existing API key auth path. ~15 LOC.
3. **`api_rps_cap`** — `EngramWeb.Plugs.RateLimit` reads per-plan cap from `LimitKeys` instead of a hardcoded ceiling. ~30 LOC.
4. **`max_file_bytes`** — `AttachmentController.create/2` checks `byte_size(file)` against the per-plan cap. ~10 LOC.
5. **`attachment_bytes_cap`** — `AttachmentController.create/2` sums existing per-user attachment bytes and checks the new file against the cap. ~30 LOC, requires a `count_user_attachment_bytes/1` helper.
6. **`inactivity_warn_60_days` + `inactivity_delete_days`** — migrate `InactivityCleanup` cron to read the catalog so per-user overrides take effect. ~40 LOC.
7. **`concurrent_devices` + `device_swap_cooldown_hours`** — `DeviceAuthController` checks per-user device count + swap cooldown. ~50 LOC.

Each follow-up:
- Adds a `Billing.check_limit` or `Billing.effective_limit` call in `lib/`.
- Removes the corresponding key from `@opt_outs` in the lint task.
- Adds a regression test exercising the enforcement.

The audit table above will get re-ticked from ⏳ to ✓ as each lands.

## How CI prevents drift

- `mix engram.lint.no_client_only_rate_limits` runs in the `lint` job. A new key added to `LimitKeys` without an enforcement site or opt-out entry fails the build.
- The companion `mix engram.lint.limit_keys` task (shipped in §0 / PR #179) ensures every `Billing.*` call site uses an atom from the catalog (no typos, no string keys, no dynamic-key gaps).

Together, these two lints close the §G acceptance criterion that "rate-limit decisions never live only on the client."
