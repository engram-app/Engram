# Context Doc: Onboarding/billing gate vs. the WebSocket sync path

_Last verified: 2026-08-19_

## Status
Working — gate now enforced on both transports (PR #1426). Test-suite coverage still compromised, see Gotchas + issue #1427.

## What This Is
Why `EngramWeb.Plugs.RequireOnboarding` could not stop an un-onboarded account from
syncing a whole vault, and where the gate actually lives now.

## Environment
Backend (`engram-app/Engram`), Elixir/Phoenix. SaaS mode only —
self-host (`billing_enabled=false`) auto-passes terms + subscription.

## The failure
Reproduced on staging 2026-08-19: an account that had **neither accepted the ToS nor
selected a plan** synced a full vault from Obsidian, and the plugin displayed it as
"Free tier" (`Billing.tier/1` returns `:free` for "no subscription", which reads as a
normal state rather than a blocked one).

`RequireOnboarding` was wired only on the vault-scoped **router** pipeline
(`router.ex:55`). It correctly 403'd `/api/notes`, `/api/search`, `/api/folders`.
But a Plug takes a `conn` and **never runs on a socket** — and sync had moved to
Phoenix Channels. The live path checked token validity (`user_socket.ex`
`connect/3`), `crdt_proto` version, the DEK rotation lock,
topic ownership, and the credential's vault scope (now `Engram.Permissions`,
the single source of truth for what a credential may reach). What it did **not** check
was entitlement: nothing asked about ToS, plan, or wizard completion.

Note the rotation check in that list — the gate is now ordered deliberately
around it (see Gotchas). A summary that omits it gives a future reader no
reason to preserve the ordering.

All the existing checks passing → join → full read/write sync. The plugin barely touches REST, so it never
met the gate it was supposed to fail. `POST /api/vaults/register` (user-scoped
pipeline, intentionally ungated so the wizard can create a first vault) supplied the
vault.

## Where the gates live now
Two layers:

- **`Engram.Onboarding.gate/2`** — the onboarding verdict itself. `:ok` or
  `{:error, missing, next_step}`, with `GateCache` pass-caching.
  `EngramWeb.Plugs.RequireOnboarding` is a thin 403-shaping wrapper over it.
- **`EngramWeb.ChannelGate.check/2`** — the socket-side equivalent of the whole
  vault-scoped pipeline. Composes lifecycle + onboarding and returns the map to
  reply straight from `join/3`. `SyncChannel` and `CrdtChannel` both call it.

The vault scope pipes `:authed_api` (`router.ex:49-60`), which runs **eleven**
plugs — not three. Do not trust a summary that says otherwise; that
miscount is what let the gaps below go unnoticed.

Listed in **pipeline execution order** (`router.ex:50-60`) — `ChannelGate`'s
`with` chain follows the same order deliberately, so do not re-sort this.

| `:authed_api` plug | HTTP | Socket |
|---|---|---|
| `PreAuthRateLimit` | 429 | ❌ — **there is no join rate limiter at all** |
| `Auth` | 401 | `UserSocket.connect/3` |
| `AccountDeleted` | 410 `account_deleted` | ✅ #1429 |
| `DeviceFingerprint` | — | ❌ |
| `RotationLockCheck` | 503 `rotation_in_progress` | ✅ #1434 |
| `RequireOnboarding` | 403 `onboarding_required` | ✅ #1426 |
| `RequireActiveSubscription` | 402 `account_suspended` | ✅ #1429 |
| `BumpActivity` | stamps `last_active_at` | ✅ #1429 — load-bearing, see below |
| `RequireApiRpsBudget` | 429 | ⚠️ #1433 — only the `cap == 0` case, at join |
| `EnforceSearchCap` | 402 | ❌ |
| `RequireApiWriteEnabled` | 402 | ❌ — attempted and reverted, see `channel_gate.ex` |

**API-key sockets are gated; JWT sockets are not.** Pricing v2 §G is a
paid-API entitlement, and the exemption keys on `current_api_key` being
**non-nil**, not on the assign existing — `UserSocket.accept/4` ALWAYS sets
that key (nil for JWT), so porting the plugs' `not is_map_key/2` guard
literally gates every web and plugin user on the platform. Device-flow and
Clerk tokens resolve with a nil key and are unaffected.

Consequence for tests: any test that mints an API key to exercise something
*else* (vault restriction, join tracing, channel logging) must first call
`grant_api_write!/1` from `Engram.ApiEntitlementHelpers`, or it fails on entitlement before reaching
what it is actually testing.

**`BumpActivity` is not bookkeeping.** It is the only writer of
`usage_meters.last_active_at`, and `Workers.InactivityCleanup` soft-deletes
Free accounts whose stamp has aged out. Enforcing lifecycle on sockets without
also stamping liveness there turns "plugin user who syncs over CRDT and rarely
touches REST" into a permanently locked-out account in daily active use.
Port the enforcement half and the liveness half together, always.

**Adding a route to the vault pipeline gets you the plugs. Adding a _channel_
gets you nothing — call `ChannelGate.check/2` from its `join/3`. And adding a
plug to the pipeline does NOT add it to sockets: decide explicitly and put it
in `ChannelGate`.**

#1426 shipped with only the middle row ported, which is exactly how the
original bug happened one layer up — a rule that lived in one transport's
plumbing. #1429 closed the other two.

## Failed Approaches / Dead Ends
- **Gating `UserSocket.connect/3`.** Tidier-looking and wrong: it deadlocks signup.
  The FTUX vault screen joins `user:{id}` mid-wizard to wait for `vault_created` /
  `vault_populated` (`user_channel.ex`), so gating the socket blocks the only path to
  *passing* the gate. `user:` must stay open; there is a test pinning it open.
- **Gating only the `/link` + vault-select OAuth flow.** That is one caller. A device
  linked before the check, a PAT, or an MCP token all still open the socket. The
  socket is where every caller converges — fix it there. (The link path is *also*
  gated now, but purely so the failure is a readable 403 instead of a silent
  channel-join refusal.)
- **Setting `free_tier_accepted_at` in `user_factory` to un-break the suite once
  `billing_enabled` is honored.** Fixes the `subscription` slice only
  (284 → ~2 failures in `controllers/`); the dominant remainder is
  `missing: ["terms"]` from a `VersionCache` leak. See Gotchas.

## Ordering (do not "tidy" this)
In `CrdtChannel`: `crdt_proto` → **topic ownership match** →
`ChannelGate.check/2` → vault resolve. In `SyncChannel`: topic ownership
match → `ChannelGate.check/2` → vault resolve.

Rotation used to sit ahead of the ownership match in `CrdtChannel`; #1434
moved it inside `ChannelGate` so `SyncChannel` gets it too. Behaviour change
worth knowing: a user mid-rotation joining a topic they do NOT own now gets
`unauthorized` rather than `rotation_in_progress`.

The gate goes last because:
- the ownership match is free, and the verdict costs ~4 DB round-trips
  (including an RLS transaction) with **no join rate limiter** — a
  `crdt:<other-user>:<uuid>` probe must not buy that;
- the plugin's identity self-heal keys on `reason === "unauthorized"`
  specifically (`channel.ts`, e2e test_84) — replacing that reason wedges it;
- a user mid-DEK-rotation on their OWN topic must still hear
  `rotation_in_progress` — `check/2` runs `rotation/1` before `onboarding/1`
  for exactly this, and there is a test on it. Only the FOREIGN-topic case
  changed: #1434 moved rotation behind the ownership match, so a mid-rotation
  user probing someone else's topic now correctly gets `unauthorized`.

There are mutation-checked tests for all three in
`onboarding_gate_channel_test.exs` ("gate ordering").

## Gotchas
- **`POST /api/auth/device/authorize` does NOT inherit the gate.** It sits on the
  user-scoped pipeline because it must stay reachable for first-vault creation, so it
  declares `plug EngramWeb.Plugs.RequireOnboarding when action in [:authorize]`
  itself. Same for anything else added to that scope.
- **`Billing.tier/1` returning `:free` is a pricing default, not an authorization
  answer.** Never treat "tier resolved" as "user is allowed here".
- **The SaaS onboarding gate has never run in the test suite.**
  `config/runtime.exs` sets `:billing_enabled` *unguarded by `config_env()`*, and
  runtime.exs loads last — so it clobbers `config/test.exs`'s `true` to `false` for
  the whole suite. Every onboarding gate is a no-op unless a case does its own
  `Application.put_env`. This is *why this bug survived*. Turning it on for real
  gives **429 failures / 4677**; the bulk is `Engram.Legal.VersionCache` (node-local
  ETS, not sandboxed) leaking a required terms floor into later `async: true` tests
  whose own rows were rolled back. Tracked in issue #1427 — do not "just add the
  guard" without (2) and (3) from that issue.
- Tests that need the real SaaS gate must `Application.put_env(:engram,
  :billing_enabled, true)` in setup **and** `GateCache.evict_all()` — the pass
  verdict is cached for 60s and is not sandboxed either.
- **`gate/2` re-reads the user row.** `status/1` derives `subscription_ok`
  partly from `user.free_tier_accepted_at` on the STRUCT while every other
  input is queried fresh. `Plugs.Auth` reloads the user per HTTP request, but
  `UserSocket` assigns `current_user` **once** at `connect/3` — so without the
  re-read a Free user who clicks "Continue with Free" mid-session re-derives
  from a stale struct on every rejoin and stays locked out for the life of the
  connection (Free is the default cohort; paid users self-heal because
  `Billing.tier/1` queries). `accept_free_tier/1` is a bare `Repo.update` with
  no socket disconnect, unlike the billing paths which pair eviction with
  `SessionInvalidator.disconnect_user/1`.
- **`user:` has a catch-all `handle_in/3`** and needs it. Phoenix dispatches
  inbound events unconditionally (`Phoenix.Channel.Server` → `handle_in/3`);
  with no clause, one client frame kills the channel process. Server-push-only
  is a client convention, not an enforced one — and this topic is reachable
  pre-onboarding by design.
- **Lifecycle is never cached and never read off the socket struct.**
  `ChannelGate.check/2` re-reads the row on every join. An admin suspension has
  to bite on the *next* join: `SessionInvalidator` kills the live socket, but
  the JWT stays valid and the client reconnects within seconds. `GateCache`
  holds PASS verdicts for 60s, so routing the lifecycle check through it would
  leave a suspended account syncing for up to a minute per node.
  `Onboarding.gate/2` takes `fresh: true` so that shared read is not paid twice.
- **`POST /api/auth/device/authorize` passes `skip_vault: true`.** It creates
  the first vault, so gating it on "you already have one" makes it permanently
  unreachable for the user who needs it. The relaxed verdict is deliberately
  **not** written to `GateCache` — the channels read the same cache and enforce
  the strict rule.
- The factory user's "already onboarded" comment is only true because the flag is
  off. It has no `free_tier_accepted_at`.

## References
- `lib/engram/onboarding.ex` — `gate/1`, `status/1`
- `lib/engram/onboarding/gate_cache.ex` — pass-cache + eviction contract
- `lib/engram_web/plugs/require_onboarding.ex`
- `lib/engram_web/channels/{sync,crdt}_channel.ex`, `lib/engram_web/user_socket.ex`
- `test/engram_web/onboarding_gate_channel_test.exs`,
  `test/engram_web/onboarding_gate_integration_test.exs`
- `lib/engram_web/channel_gate.ex` — the socket-side pipeline equivalent
- `test/engram_web/lifecycle_gate_channel_test.exs`
- PR #1426 (onboarding), PR for #1429 (lifecycle), issue #1427 (test-config
  follow-up), #1430 (SPA drops writes on a refused join),
  Engram-obsidian#455 (plugin degrades to a dead REST path), #142
