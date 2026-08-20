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
`connect/3`), `crdt_proto` version, `RotationGate.check/1` (DEK rotation lock),
topic ownership, and `Vaults.check_api_key_access/2`. What it did **not** check
was entitlement: nothing asked about ToS, plan, or wizard completion.

Note the rotation check in that list — the gate is now ordered deliberately
around it (see Gotchas). A summary that omits it gives a future reader no
reason to preserve the ordering.

All the existing checks passing → join → full read/write sync. The plugin barely touches REST, so it never
met the gate it was supposed to fail. `POST /api/vaults/register` (user-scoped
pipeline, intentionally ungated so the wizard can create a first vault) supplied the
vault.

## Where the gate lives now
`Engram.Onboarding.gate/1` is the **single authority**. Returns `:ok` or
`{:error, missing, next_step}` and keeps the `GateCache` pass-caching.

- `EngramWeb.Plugs.RequireOnboarding` — thin 403-shaping wrapper (HTTP).
- `SyncChannel.join/3` + `CrdtChannel.join/3` — reply
  `{:error, %{reason: "onboarding_required", missing: [...], next_step: ...}}`.

**Adding a route to the vault pipeline gets you the plug. Adding a _channel_ does
not — call `Onboarding.gate/1` from its `join/3`.**

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
In `CrdtChannel`: `crdt_proto` → `RotationGate.check/1` → **topic ownership
match** → `Onboarding.gate/1` → vault resolve. In `SyncChannel`: topic
ownership match → `Onboarding.gate/1` → vault resolve.

The gate goes last because:
- the ownership match is free, and the verdict costs ~4 DB round-trips
  (including an RLS transaction) with **no join rate limiter** — a
  `crdt:<other-user>:<uuid>` probe must not buy that;
- the plugin's identity self-heal keys on `reason === "unauthorized"`
  specifically (`channel.ts`, e2e test_84) — replacing that reason wedges it;
- a user mid-DEK-rotation must still hear `rotation_in_progress` (T3.7).

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
- PR #1426 (fix), issue #1427 (test-config follow-up), #142 (RequireOnboarding)
