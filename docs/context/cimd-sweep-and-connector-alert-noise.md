# CIMD refresh sweep and the connector alerts that fire daily

_Last verified: 2026-11-11_

Related: [[cimd-vs-dcr-validation-policy]], [[mcp-oauth]]. Fix: PR #2562 (`fix/cimd-sweep-active-clients`).

## Triggers

- `engram-prod-loki-mcp-connector-refused` fires about once a day.
- A CIMD client host is dead and `mcp_cimd_fetch_failed` repeats for it.
- The sweep line says `unchanged=` for a client that actually failed to refetch.
- `engram-prod-oauth-rate-limited` fires from a group of people on one network.

## Alert 1: mcp-connector-refused

Rule: engram-infra group `engram-prod-loki-categories`. LogQL counts `mcp_cimd_rejected|mcp_cimd_stale_retained|oauth_client_assertion_rejected|oauth_client_assertion_malformed|oauth_client_rejected|mcp_jwks_unusable` over `[60m]`, threshold 0, `for 2m`.

- One failed CIMD refetch writes four warning lines: `mcp_cimd_fetch_failed` x2 (two attempts to the same pinned IP, each ending at the 1.5s connect timeout), then `mcp_cimd_rejected` and `mcp_cimd_stale_retained`. The alert matches only the last TWO; `mcp_cimd_fetch_failed` is not in its filter. A limiter refusal (`:rate_limited`) logs none of them.
- The 60m window keeps it firing about an hour after the last line; NoData then resolves it. A once-a-day failure therefore looks like a daily alert.

### Root cause

`Engram.Workers.CimdRefresh` (cron `40 5 * * *`, `config/config.exs`) refetched EVERY client with a `cimd_url`, forever. A dead test client (Harness, host `dev.1mlight.xyz`, TCP 80/443 time out, no live refresh token, last good fetch 2026-11-04) failed daily from 2026-11-05.

### Fix

- Document sweep refreshes a client if it has a live refresh token (unrevoked AND unexpired, any `last_used_at`) OR `cimd_fetched_at` is NULL or within `dead_after_days/0` (`Application.get_env(:engram, :cimd_dead_after_days)`, unset in config files, default 7).
- JWKS sweep keeps its 30-day last_used rule (`active_days/0`, `Application.get_env(:engram, :cimd_active_days)`, unset in config files, default 30).
- `cimd_fetched_at` only moves on a SUCCESSFUL fetch, which is why it is the dead-host signal. Nothing deletes or updates `oauth_clients`.
- A skipped client refreshes on demand via `Cimd.ensure_client/1` at authorize. A recovered host nobody tries to connect to stays skipped until someone authorizes.
- The sweep tally now reports `fresh/refreshed/stale_retained` via `Cimd.ensure_client_status/1`. Before, a failed refetch was folded into `unchanged`. `ensure_client/1` is a thin wrapper, byte-identical for the authorize path (pinned in `test/engram/oauth/cimd_test.exs`).

### Why not "skip every client with no live grant"

Prod has (read-only query, 2026-11-11) 17 CIMD clients: 9 with a live refresh token, 8 with no live refresh token today (Antigravity, Flowy, Harness, Spiich, Zed, ChatGPT, Irene, Telosnex). No refresh-token ROW today does not mean the client never connected: `Engram.OAuth.cleanup_expired/0` (`lib/engram/oauth.ex`, ~1687-1745) deletes consumed (rotated) tokens after 24h, revoked families and expired tokens after 7 days. ChatGPT also uses a per-connector CIMD URL, so one vendor has MANY client rows (prod: row 88b89099 holds ~4,978 tokens, 4,814 live, plus others; the chatgpt.com row among the 8 is one abandoned connector).

So "no live grant" alone is also true of healthy abandoned rows whose host still answers, and skipping them would silence a free early warning (7 of the 8 are healthy vendors). Skipping needs TWO independent signals: no live grant AND a stale last-good fetch. The fetch staleness (`cimd_fetched_at` older than `dead_after_days/0`) is the direct dead-host signal; the grant check only protects clients people still use.

## Prod funnel facts (window 2026-10-21 to 2026-11-11; source `analytics_events`, which only has data since Oct 21, plus the oauth tables; read-only, 2026-11-11)

- `mcp_oauth_authorize_started` 2,558 (all anonymous by design), `granted` 1,368, `token_issued` 76,656 (refresh_token grants dominate), `token_failed` 2,971 (437 anonymous), `code_expired` 97, `authorize_rejected` 3.
- chatgpt (cimd): started 2,340, granted 1,244, code tokens 1,163, refresh tokens 60,269, failed 2,868 = 2,446 refresh_token / invalid_grant / refresh_token_revoked (across only 9 users, dead-token retry loops) + 397 refresh_token_unknown + 25 other reasons.
- zed (cimd): 5 started, 5 granted, 5 code tokens, 54 failed refreshes (49 revoked) from 1 user.
- The `other` bucket also holds Codex (client_agent=codex, 1,636 events) and unmapped vendors (13,536 events with client_agent=other), so per-vendor numbers for Antigravity, Telosnex, Grok and others are invisible today.
- The retry-loop issues are tracked as #2333 and #2299.

## Alert 2: oauth-rate-limited

Metric `engram_prom_ex_rate_limiter_hit_total{purpose="oauth",result="deny"}`. Fired 2026-11-10 22:43Z from a group behind ONE /24 (Tempo `client.address` is scrubbed to /24 by `span_scrubber.ex`; mixed user agents) hitting `GET /oauth/authorize`: 27 requests in about 70s around 22:37Z: 10 allowed, then 8 denied, then 9 allowed after the window rolled. That matched the OLD per-IP 10/min default; PR #2542 (v0.80.0) raised `/oauth/authorize` and `/api/oauth/clients` to 300/IP/min (`@consent_path_policy` in `lib/engram_web/plugs/oauth_rate_limit.ex`).

Lesson: a per-IP limiter on a consent path throttles shared networks (retreats, offices).

## Diagnose next time

- 24h alert history: Grafana `/api/annotations?type=alert`.
- Loki: `{service="engram", env="prod"} |= "<cimd_host>"` (query range cap is 30 days). Sweep line per day: `mcp_cimd_refresh_sweep total=N fresh=.. refreshed=.. stale_retained=..`.
- Tempo: `{ span.http.route =~ "/oauth.*" && span.http.response.status_code = 429 }`.
- Prod DB counts need the read-only bastion under the shared-bastion rules (one statement per transaction, `BEGIN READ ONLY`, `statement_timeout` 5s, `idle_in_transaction_session_timeout` 10s, stop the bastion after). See engram-infra `docs/context/prod-db-readonly-access.md`; do not copy it here.
- Local traps: run the SSM tunnel on a local port other than 5432 (a local docker postgres owns 5432 and answers "server does not support SSL"); `python3 -I` hides pip `--user` packages.

## Not verified

- Grafana UI-only dashboard panels that might still read the old `unchanged=` key.
- Whether the second Telosnex failure came from a stale CDN copy (their own document was a vendor-side problem, now valid JSON; no action taken).
