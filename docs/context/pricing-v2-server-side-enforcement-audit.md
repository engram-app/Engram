# Pricing v2 §G — Server-Side Enforcement Audit

**Date:** 2026-05-21 (shipped with PR #198).

> **Snapshot — catalog has drifted.** This is a point-in-time audit of the `LimitKeys` catalog as of the date above. Since then the catalog moved (now at `lib/engram/billing/limit_keys.ex`): `realtime_sync_enabled` and `inactivity_warn_60_days` listed below are dead, and roughly eight newer keys are not represented here. Treat the table as historical; re-run `mix engram.lint.no_client_only_rate_limits` for the live picture.

Closes pricing-v2 §G's audit criterion: walk every `LimitKeys` catalog key and confirm each Free-restrictive limit has a server-side enforcement site. The `mix engram.lint.no_client_only_rate_limits` task encodes this audit and runs in CI on every push.

## Audit results

| Key | Free default | Server-side enforcement |
|-----|--------------|-------------------------|
| `notes_cap` | 10_000 | `Engram.Notes.insert_new_note/5` → `Billing.check_limit/3` → 402 (NEW in this PR) |
| `vaults_cap` | 1 | `Engram.Vaults.create_vault/2` + `register_vault/3` |
| `attachment_bytes_cap` | 1 GB | `Engram.Attachments.validate_storage_cap/3` inside the per-path advisory lock — sums non-deleted bytes via `storage_usage/1`, subtracts existing row size on upsert, rejects with 402 `storage_cap_reached` (body carries `used` + `limit`) |
| `max_file_bytes` | 10 MB | `Engram.Attachments.validate_size/2` — `Billing.effective_limit(user, :max_file_bytes)` checked against decoded byte_size; 413 with `limit` in body. `StorageController.index/2` exposes the same per-plan number. Schema-level hardcoded 5 MB removed |
| `lifetime_embed_token_cap` | 20 M | `Engram.Workers.EmbedNote.embed_budget_gate/1` |
| `concurrent_devices` | 1 | ⏳ opt-out (`DeviceAuthController` needs explicit count check) |
| `device_swap_cooldown_hours` | 12 | ⏳ opt-out (`DeviceAuthController` needs cooldown check) |
| `realtime_sync_enabled` | false | `EngramWeb.SyncChannel.join/3` → `channel_forbidden_on_plan` (NEW in this PR; env-gated by `REALTIME_SYNC_GATE_ENABLED`, defaults off — flip on launch day so pre-v2 Free users aren't kicked off sync mid-flight) |
| `ai_conversations_per_day` | 5 | `Engram.ConversationMeter.day_cap_exceeded?/2` |
| `ai_queries_per_conversation` | 50 | `Engram.ConversationMeter.maybe_rotate_conversation/3` |
| `ai_queries_per_day` | nil (Free unmetered via conv cap) | `Engram.ConversationMeter.query_day_cap_exceeded?/2` |
| `conversation_window_minutes` | 30 | `Engram.ConversationMeter.maybe_rotate_conversation/3` |
| `reranker_enabled` | false | `Engram.Search.do_search/4` — per-user check via `Billing.check_feature/2`; Free/Starter route through `Engram.Rerankers.None` even when Jina is globally configured |
| `api_write_enabled` | false | `EngramWeb.Plugs.RequireApiWriteEnabled` on the vault-scoped pipeline — gates non-GET requests when authed via API key (JWT path exempt). POST `/api/search` exempt as a read-via-POST. 402 with `api_write_not_available` |
| `api_rps_cap` | 0 | `EngramWeb.Plugs.RequireApiRpsBudget` on user-scoped + vault-scoped pipelines — Hammer-backed, 1-sec window keyed on `api_rps:user_id`. JWT path exempt. 429 with `api_rps_exceeded`. Free=0 → instant 429 |
| `inactivity_warn_60_days` | true | ⏳ opt-out — `InactivityCleanup` cron uses `Billing.tier/1` rather than reading the key directly |
| `inactivity_delete_days` | 90 | ⏳ opt-out — same as above |
| `cross_vault_search` | false | ⏳ opt-out (legacy UX flag) |
| `vault_scoped_keys` | false | ⏳ opt-out (legacy; superseded by `api_key_vaults`) |

## What "opt-out" means

The lint task allows a catalog key to skip server-side enforcement IFF it is listed in `Mix.Tasks.Engram.Lint.NoClientOnlyRateLimits.@opt_outs` with a reason string. Adding a new restrictive key to `LimitKeys` without either a server-side check or an opt-out entry fails CI via both the lint task itself AND the self-scan meta-test.

## Follow-ups before launch

Each ⏳ opt-out above is a follow-up PR. Suggested order, smallest-first:

1. ~~**`reranker_enabled`**~~ — ✅ SHIPPED. `Engram.Search.reranker_active_for?/1` gates per-user via `Billing.check_feature/2`.
2. ~~**`api_write_enabled`**~~ — ✅ SHIPPED. `EngramWeb.Plugs.RequireApiWriteEnabled` on vault pipeline; API-key-only with JWT exemption + `/api/search` carve-out.
3. ~~**`api_rps_cap`**~~ — ✅ SHIPPED. `EngramWeb.Plugs.RequireApiRpsBudget` on user-scoped + vault-scoped pipelines; API-key-only; Hammer-backed 1-sec window.
4. ~~**`max_file_bytes`**~~ — ✅ SHIPPED. `Engram.Attachments.validate_size/2` pulls per-plan cap from `Billing.effective_limit/2`; schema-level hardcoded 5 MB removed; `StorageController` surfaces per-plan ceiling.
5. ~~**`attachment_bytes_cap`**~~ — ✅ SHIPPED. `Engram.Attachments.validate_storage_cap/3` sums non-deleted bytes (subtracts existing on upsert), 402 `storage_cap_reached` with `used` + `limit` in body.
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
