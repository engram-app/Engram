# Context Doc: Self-host install census

_Last verified: 2026-10-03_

## Status
Working in code (PR engram-app/Engram#1828, not yet merged). NOT verified through the real Cloudflare edge.

## What This Is
Daily census of self-host installs, **on by default** (decision 2026-10-03: opt-in would undercount badly, and an install whose admin never opens the UI would never ping). Self-host POSTs `{id, version, os, arch, runtime}` to the SaaS collector; SaaS exposes a Grafana gauge.

## Sender (self-host)
- `lib/engram/telemetry/heartbeat.ex` (payload, `enabled?/0`, `send_ping/0`) + `lib/engram/workers/telemetry_heartbeat.ex`, Oban cron `17 5 * * *` (`config/config.exs:157`).
- Payload is exactly `{id, version, os, arch, runtime}`. Nothing else, ever.
- `id` = random uuid in `instance_telemetry.install_id` (`Engram.Instance.install_id/0`; `INSERT ... ON CONFLICT DO NOTHING` then read back, so concurrent mints converge on the first).
- State = `instance_telemetry.telemetry_enabled`, tri-state: `NULL` = never answered (counts as ON), `true` = acknowledged, `false` = turned off. Off on SaaS (`:billing_enabled`). `ENGRAM_TELEMETRY=false` overrides everything (the one env var, deliberately: `DO_NOT_TRACK` is ignored; `true` does not override an admin who turned it off). `Heartbeat.log_boot_notice/0` prints one boot line naming the switches so the default is never silent.
- URL is hardcoded `https://api.engram.page/api/telemetry/ping`. `app.engram.page` 405s API POSTs (workspace `docs/context/public-url-host-split.md`).

## Collector (SaaS)
- `POST /api/telemetry/ping` -> `InstallPingController` (`router.ex:311`, `:rate_limit_auth` pipeline = 10/min/IP). Upserts `install_pings` by id (`lib/engram/telemetry/install_pings.ex`); enum validation in `Engram.Telemetry.InstallPing`. 404 on self-host.
- Post-deploy smoke test (not yet done): `curl -i -X POST https://api.engram.page/api/telemetry/ping -H 'content-type: application/json' -d '{...valid payload...}'`, expect 204. 405/403 = Cloudflare/WAF blocking POSTs.

## Admin UI (self-host)
- `GET/PATCH /api/admin/telemetry` (`router.ex:520-521`, `EngramWeb.Admin.TelemetryController`). PATCH because the SPA api client has no `put`.
- `frontend/src/features/admin/TelemetryTab.tsx`: a plain toggle under Administration > Usage statistics, with the exact payload. There is deliberately NO first-run card/toast on the home screen (a "Got it" / "Turn off" `TelemetryPrompt` shipped in #1828 and was removed before the first release at the owner's request); disclosure is the boot log line, this tab, and the docs page. `telemetry_enabled = true` is therefore only ever set by toggling the tab.

## Visibility
`engram_prom_ex_installs_seen{os,arch,runtime}` PromEx polling gauge (`lib/engram/prom_ex/installs.ex`), 30-day window, SaaS only. All 24 enum combos (4x3x2) emitted every poll including zeros, because a `last_value` for a vanished label set freezes at its last value. Aggregate with `max`, not `sum` (every node reports the same DB count). Never add `version` or `id` as a label.

## Privacy claim (verified)
The app does not store or log the client IP. `EngramWeb.RemoteIp` resolves it in memory only for the rate-limit key (`plugs/rate_limit.ex`); no ALB access_logs in engram-infra Terraform. Cloudflare in front still sees it. Defensible copy: "we do not store your IP address", NOT "never see". Read workspace `docs/context/market-position-and-gtm.md` section 5 before writing any other marketing copy.

## Known ceiling
Collector is unauthenticated: one IP can inflate the count up to the rate limit (10/min). Fine for a census, not for billing.

## Gotchas
1. `config/runtime.exs:461` sets `:billing_enabled` UNCONDITIONALLY, so it is FALSE in test even though `config/test.exs:211` says true. Tests needing SaaS behaviour must `Application.put_env` it.
2. `test/lint/skip_tenant_check_inventory_test.exs` is a count ratchet over every `skip_tenant_check: true`. Adding a site fails it until the count is bumped (instance.ex 4->7, install_pings.ex +1, prom_ex/installs.ex +1). `install_pings` and `instance_settings` are non-tenant tables.
3. Dialyzer `unmatched_return` fires on a fire-and-forget statement-level `if`/`for`. Discard with `_ =` on the whole expression or use `Enum.each`.
4. Test filename collision: `EngramWeb.TelemetryController` (authed `/telemetry/spans`) already existed, hence the collector is `InstallPingController`. A heredoc once overwrote `test/engram_web/controllers/telemetry_controller_test.exs` (restored with `git checkout`). Check `git status` / `ls` before writing a new test file.
5. Worktree bootstrap: the post-checkout hook is in `.githooks/` but `core.hooksPath` is `.git/hooks`, so a fresh worktree has no deps. Run `cp -al ../../deps deps` then `mix deps.get` (main checkout deps can be stale vs `mix.lock`); frontend: `cp -al ../../../frontend/node_modules` + `bun install --frozen-lockfile`. Backend mix/git need `mise exec --`.

## Follow-ups not done
- Grafana panel (lives in engram-infra).
- Public self-host docs page (engram-marketing, `src/content/docs/docs/self-host/telemetry.mdx`).

## Default-on consequences (2026-10-03)

- Marketing copy that said "no telemetry" / "off by default" had to change in the same
  release: `engram-marketing` `src/pages/index.astro`, `src/lib/features.ts` (+ 10 locale
  strings), `docs/why-engram`. Check those before changing the default again.
- `config/test.exs` pins `:logger` to `:warning`, so a test of an `info` log line must
  `Logger.configure(level: :info)` or its "silent" cases pass vacuously.
- Privacy policy (`engram-marketing` `src/legal/`) does not mention self-host at all; whether
  the ping needs a line is a legal call, left open.

- Retention: `Engram.Workers.InstallPingsPruner` (cron `30 4 * * *`) deletes rows with `updated_at` older than 35 days (> the gauge's 30-day window), in 5k batches.

- Prod-only gate (code review #2): `config :engram, :census_ping, config_env() == :prod` in `config/config.exs`; `Heartbeat.allowed?/0` requires it, so a dev `mix phx.server` or any source run never pings the real collector and pollutes the count. Tests that exercise the sender must `Application.put_env(:engram, :census_ping, true)` (and restore it), exactly like `:billing_enabled`. A prod-built Docker CI stack still pings if it is up at 05:17 UTC; accepted (daily, short-lived).
- Accepted, not fixed: the collector's counts are spoofable (any UUID, bounded only by the rate limit and the 35-day pruner); treat `engram_prom_ex_installs_seen` as an estimate.

- **Why census state has its own table, not `instance_settings`** (code review): the daily ping can run on a fresh instance before any admin exists. An `instance_settings` row created that early bakes in a `registration_mode` and silently freezes `ENGRAM_DEFAULT_REGISTRATION_MODE` (`registration_mode/0` reads the row once one exists). Making the column nullable was the first idea, but squawk's `ban-drop-not-null` rejects `DROP NOT NULL`. The singleton `instance_telemetry` row (same sentinel id) sidesteps both; `install_id` / `set_telemetry_enabled` never touch `instance_settings`, and a test asserts it.
- **PromEx metric names carry `prom_ex`:** `PromEx.metric_prefix(:engram, :installs)` is `[:engram, :prom_ex, :installs]`, so the gauge is `engram_prom_ex_installs_seen`, not `engram_installs_seen`. Dashboard and alert queries must use the full name (confirmed by `mix run --no-start`, and by the existing `engram_prom_ex_crdt_*` series).
- Env parsing: `ENGRAM_TELEMETRY` disables on `false` (also `0`/`no`/`off`, any case, trimmed); any other value defers to the in-app setting. Known gap, accepted: installs behind one NAT share the collector's 10/min/IP bucket and all fire at 05:17 UTC, so a large NAT could drop pings silently (census undercounts).
- Local test DB tip: `MIX_TEST_PARTITION=_name` gives an isolated, freshly migrated `engram_test_name` database. The shared `engram_test` is polluted by other worktrees' migrations (e.g. `note_revisions` breaks `RepoTenantGuardTest`).

