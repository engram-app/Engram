# CIMD refresh sweep and the connector alerts that fire daily

_Last verified: 2026-11-11_

Related: [[cimd-vs-dcr-validation-policy]], [[mcp-oauth]]. Fix: PR #2562 (`fix/cimd-sweep-active-clients`).

## Triggers

- `engram-prod-loki-mcp-connector-refused` fires about once a day.
- A CIMD client host is dead and `mcp_cimd_fetch_failed` repeats for it.
- The sweep line says `unchanged=` for a client that actually failed to refetch.
- `engram-prod-oauth-rate-limited` fires from a group of people on one network.

## Alert 1: mcp-connector-refused

Rule: engram-infra group `engram-prod-loki-categories`. LogQL counts `mcp_cimd_rejected|mcp_cimd_stale_retained|oauth_client_assertion_*|oauth_client_rejected|mcp_jwks_unusable` over `[60m]`, threshold 0, `for 2m`.

- One failed CIMD refetch writes FOUR matching lines: `mcp_cimd_fetch_failed` x2 (two attempts to the same pinned IP, 1.5s apart), `mcp_cimd_rejected`, `mcp_cimd_stale_retained`.
- The 60m window keeps it firing about an hour after the last line; NoData then resolves it. A once-a-day failure therefore looks like a daily alert.

### Root cause

`Engram.Workers.CimdRefresh` (cron `40 5 * * *`, `config/config.exs`) refetched EVERY client with a `cimd_url`, forever. A dead test client (Harness, host `dev.1mlight.xyz`, TCP 80/443 time out, 0 refresh tokens ever, last good fetch 2026-11-04) failed daily from 2026-11-05.

### Fix

- Document sweep refreshes a client if it has a live refresh token (unrevoked AND unexpired, any `last_used_at`) OR `cimd_fetched_at` is NULL or within `dead_after_days/0` (default 7, `config :cimd_dead_after_days`).
- JWKS sweep keeps its 30-day last_used rule (`active_days/0`, `:cimd_active_days`).
- `cimd_fetched_at` only moves on a SUCCESSFUL fetch, which is why it is the dead-host signal. Nothing deletes or updates `oauth_clients`.
- A skipped client refreshes on demand via `Cimd.ensure_client/1` at authorize. A recovered host nobody tries to connect to stays skipped until someone authorizes.
- The sweep tally now reports `fresh/refreshed/stale_retained` via `Cimd.ensure_client_status/1`. Before, a failed refetch was folded into `unchanged`. `ensure_client/1` is a thin wrapper, byte-identical for the authorize path (pinned in `test/engram/oauth/cimd_test.exs`).

### Why not "skip every client with no live grant"

Prod has 17 CIMD clients: 9 with a live token, 8 with ZERO tokens ever (Antigravity, Flowy, Harness, Spiich, Zed, ChatGPT, Irene, Telosnex). 7 of those 8 are healthy vendors, and the daily refresh is the early warning for a vendor that has never connected (ChatGPT, Zed).

## Alert 2: oauth-rate-limited

Metric `engram_prom_ex_rate_limiter_hit_total{purpose="oauth",result="deny"}`. Fired 2026-11-10 22:43Z from a group behind ONE /24 (Tempo `client.address` is scrubbed to /24 by `span_scrubber.ex`; mixed user agents) hitting `GET /oauth/authorize`: 27 requests in about 70s, 10 allowed then 8 denied. That matched the OLD per-IP 10/min default; PR #2542 (v0.80.0) raised `/oauth/authorize` and `/api/oauth/clients` to 300/IP/min (`@consent_path_policy` in `lib/engram_web/plugs/oauth_rate_limit.ex`).

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
