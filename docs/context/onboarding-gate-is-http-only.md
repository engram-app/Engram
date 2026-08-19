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
Phoenix Channels. The live path checked exactly two things:

- `lib/engram_web/user_socket.ex` `connect/3` — is the token valid?
- `lib/engram_web/channels/crdt_channel.ex` `join/3` — do you own this vault, and is
  `crdt_proto` new enough?

Both yes → join → full read/write sync. The plugin barely touches REST, so it never
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
