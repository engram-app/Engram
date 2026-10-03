# Context Doc: Self-host install census

_Last verified: 2026-10-03_

## Status
Working in code (PR engram-app/Engram#1828, not yet merged). NOT verified through the real Cloudflare edge.

## What This Is
Opt-in daily census of self-host installs. Self-host POSTs `{id, version, os, arch, runtime}` to the SaaS collector; SaaS exposes a Grafana gauge.

## Sender (self-host)
- `lib/engram/telemetry/heartbeat.ex` (payload, `enabled?/0`, `send_ping/0`) + `lib/engram/workers/telemetry_heartbeat.ex`, Oban cron `17 5 * * *` (`config/config.exs:157`).
- Payload is exactly `{id, version, os, arch, runtime}`. Nothing else, ever.
- `id` = random uuid in `instance_settings.install_id` (`Engram.Instance.install_id/0`, `mint_install_id` uses a COALESCE upsert so concurrent mints keep the first).
- Opt-in = `instance_settings.telemetry_enabled`, tri-state (NULL = never asked). Off on SaaS (`:billing_enabled`). `DO_NOT_TRACK=1` or `ENGRAM_TELEMETRY=off` override a stored opt-in.
- URL is hardcoded `https://api.engram.page/api/telemetry/ping`. `app.engram.page` 405s API POSTs (workspace `docs/context/public-url-host-split.md`).

## Collector (SaaS)
- `POST /api/telemetry/ping` -> `InstallPingController` (`router.ex:311`, `:rate_limit_auth` pipeline = 10/min/IP). Upserts `install_pings` by id (`lib/engram/telemetry/install_pings.ex`); enum validation in `Engram.Telemetry.InstallPing`. 404 on self-host.
- Post-deploy smoke test (not yet done): `curl -i -X POST https://api.engram.page/api/telemetry/ping -H 'content-type: application/json' -d '{...valid payload...}'`, expect 204. 405/403 = Cloudflare/WAF blocking POSTs.

## Admin UI (self-host)
- `GET/PATCH /api/admin/telemetry` (`router.ex:520-521`, `EngramWeb.Admin.TelemetryController`). PATCH because the SPA api client has no `put`.
- `frontend/src/features/admin/TelemetryTab.tsx`, `TelemetryPrompt.tsx` (ask-once card in `layout/app-layout.tsx`, self-host admins only).

## Visibility
`engram_installs_seen{os,arch,runtime}` PromEx polling gauge (`lib/engram/prom_ex/installs.ex`), 30-day window, SaaS only. All 24 enum combos (4x3x2) emitted every poll including zeros, because a `last_value` for a vanished label set freezes at its last value. Aggregate with `max`, not `sum` (every node reports the same DB count). Never add `version` or `id` as a label.

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
