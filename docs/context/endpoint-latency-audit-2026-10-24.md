# Endpoint latency audit (2026-10-24)

How to measure prod HTTP endpoint latency correctly, plus the 7-day baseline taken on 2026-10-24 and the open questions it raised.

## How to measure

### Prometheus (PromEx) gives an exact mean, not percentiles

- The PromEx request-duration histogram buckets are **10 / 100 / 500 / 1000 / 5000 ms**. Any `histogram_quantile` over them is interpolation across a 4-second-wide bucket, so its p95/p99 are useless.
- The histogram's `_sum / _count` is exact. Use it for the **mean** per route.
- Rank routes by **total time** (`count x mean`, i.e. `increase(_sum[7d])`), not by tail latency. Total time is what costs CPU, connection slots and user wait; a slow but rare route matters less than a moderately slow hot one.

### Tempo gives percentiles, with caveats

- Tempo metrics queries (`quantile_over_time`, `rate`) are capped at a **24h** range. For a 7-day view, run seven 24h windows.
- Values like **67.108864 ms** or **268.435456 ms** are power-of-2 bucket edges (2^26 ns, 2^28 ns), not real measurements. Identical values across routes mean they landed in the same bucket. See the workspace doc `tempo-quantile-power-of-2-buckets.md`.
- Traces started by the plugin include the **client span** as root, which adds network time and client-side waits. Use the **server span** duration (the Phoenix/Bandit span) when comparing server cost.

## Baseline: 7 days ending 2026-10-24

Mean is the exact PromEx `_sum/_count`. Total = count x mean.

| Route | Requests | Mean | Total | Notes |
|---|---|---|---|---|
| `POST /api/attachments` | 35.3k | 665 ms | 6.5 h | 415 rejections average 3.0 s and account for 3.7 h of the total |
| `POST /api/mcp` | 208k | 24 ms | 1.4 h | 40% are 1.6 ms bot 401s, 24% are `GET` 405s |
| `GET /api/attachments/*path` | | | 0.65 h | |
| `POST /api/logs` | 33.5k | 59 ms | | 34% are 426 (plugin too old) and take 82% of route time: 166 ms median vs 9 ms for accepted requests |
| `GET /api/sync/manifest` | 33.5k | 27 ms | | p99 176 ms |
| `POST /oauth/token` | 12.8k | 32 ms | | |
| `POST /api/auth/token/refresh` | 8.1k | 17 ms | | |

Takeaways:

- The single biggest time sink is attachment uploads that end in **415**. The rejection happens after seconds of work, so rejecting earlier (before reading or processing the body) is the cheapest large win.
- On `/api/logs`, rejected (426) requests cost far more than accepted ones. The version check runs after auth and plan lookups (see code findings below).

## Unexplained: pre-DB dead time on slow requests

Slow requests on `/api/logs`, `/api/sync/manifest`, `/api/auth/token/refresh`, `/oauth/token` and `/api/mcp` spend **0.5 to 10 s before the first DB query**, with no child spans covering the gap.

Examples:

- refresh: trace `a238dd72c2dab342ca21a8da0d2a7ba7`, 7.8 s total, 10 ms of DB.
- oauth/token: trace `1f5ffb0ea8df08c3c261bac34e0f2730`, 10.2 s total, all DB in the last 25 ms.
- mcp: trace `5b84eda40129f5b0e750deb458fe9d83`, 7.3 s total, zero child spans.

Not saturation: CPU was under 26% and DB pool wait was 20 to 100 us at the time.

Candidates, none confirmed:

1. Reading the request body from a slow client (mobile, poor network).
2. The rate limiter.
3. Auth plugs.
4. Untraced outbound HTTP: Clerk, CIMD document fetch and JWKS fetch have no spans, so any wait on them is invisible.

Next step: add spans around body read, the rate-limit check, each auth plug and the outbound HTTP clients, then re-pull the slow traces.

## Code-side findings (not verified against traces)

- **Manifest renders the full vault** whenever `since_seq != change_seq` (`lib/engram_web/controllers/sync_controller.ex:103-205`). Any client one change behind gets the whole vault.
- The **plugin has 7 full-manifest call paths** that send no `since_seq`, including a 30 s delete-guard lookup (plugin `src/sync.ts:1111` and `:1136`).
- Manifest trace `da96769150b65165083fd3c4090be391` contained a **741 ms query on the attachments table**. Check its index coverage.
- `/api/logs`: the **426 version check runs after the auth and plan lookups**. Moving it first would make rejected requests nearly free.
- `priv/repo/structure.sql` on `origin/main` is **stale** (for example it lacks `cimd_url`). Do not trust it for index checks; read the migrations in `priv/repo/migrations/` instead.
