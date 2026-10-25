# Endpoint latency audit (2026-10-24)

How to measure prod HTTP endpoint latency correctly, the per-route baseline taken on 2026-10-24, and the open questions it raised.

## How to measure

### Prometheus (PromEx) gives an exact mean, not good tail percentiles

- PromEx 1.12.0 HTTP duration buckets are **10 / 100 / 500 / 1,000 / 5,000 / 10,000 / 30,000 ms** (`deps/prom_ex/lib/prom_ex/plugins/phoenix.ex:295`). A `histogram_quantile` above 100 ms interpolates across a 400 ms to 20 s wide bucket, so p95/p99 for slow routes mean little. Below 100 ms the bucket is 90 ms wide, which is coarse but usable for fast routes.
- The histogram's `_sum / _count` is exact. Use it for the **mean** per route.
- Rank routes by **total time** (`increase(_sum[window])`), not by tail latency. Total time is what costs CPU, connection slots and user wait.
- Pick a window that starts after any relevant fix ships, or a fixed problem dominates the ranking (see the attachment 415s below).

### Tempo gives percentiles, with caveats

- Values like **67.108864 ms** or **268.435456 ms** are power-of-2 bucket edges (2^26 ns, 2^28 ns), not real measurements. Identical values across routes mean they landed in the same bucket.
- Traces started by the plugin include the **client span** as root, which adds network time and client-side waits. Use the **server span** (the Bandit span) when comparing server cost.

## Baseline: 7 days ending 2026-10-24 23:59 UTC

Source: Grafana Cloud Prometheus, `engram_prom_ex_phoenix_http_request_duration_milliseconds_{sum,count}`, `increase(...[7d])`. Mean = sum / count. Total = sum.

| Route | Requests | Mean | Total | Notes |
|---|---|---|---|---|
| `POST /api/attachments` | 33,181 | 712 ms | 6.56 h | 4,409 were 415s (mean 3.06 s, 3.74 h). Fixed, see below |
| `POST /api/mcp` | 230,961 | 27 ms | 1.76 h | 86,743 (38%) are 401s |
| `GET /api/mcp` | 68,965 | under 1 ms | 0.001 h | Separate series, not part of the POST row |
| `GET /api/attachments/*path` | 35,771 | 65 ms | 0.64 h | |
| `POST /api/logs` | 35,387 | 59 ms | 0.58 h | 12,087 (34%) are 426, mean 140 ms, 81% of route time. Accepted 200s: 23,271, mean 16.6 ms |
| `GET /api/sync/manifest` | 36,890 | 27 ms | 0.28 h | |
| `POST /oauth/token` | 13,937 | 34 ms | 0.13 h | |
| `POST /api/auth/token/refresh` | 8,866 | 18 ms | 0.05 h | |

### Attachment 415s: resolved by #2075

The 415 (`extension_not_allowed`) sink was real in that window but is gone. #2075 (sync any non-executable attachment, merged 2026-10-21) narrowed 415 to executable extensions only. Daily 415 count on `POST /api/attachments`: 10-20: 2,117, 10-21: 558, 10-22: 191, and **zero** in the 3 days ending 2026-10-25 12:00 UTC.

The extension check is already the controller's first step on `origin/main` (`attachments_controller.ex`, `do_upload_gated/4`, before `upload_raw`/`do_upload`). Any body cost a rejected request still paid sat in `Plug.Parsers` / `EngramWeb.Plugs.BodyParser`, before the controller. No controller change is needed.

Ranking after the fix (3 days, 2026-10-22 12:00 to 2026-10-25 12:00 UTC, total time): `POST /api/mcp` 1.65 h, `POST /api/attachments` 0.98 h, `GET /api/attachments/*path` 0.44 h, `POST /api/logs` 0.17 h, `GET /api/sync/manifest` 0.14 h.

### `/api/logs` 426s: unexplained, and do not reorder the plugs

Rejected (426, plugin below the version floor) requests average 140 ms; accepted (200) requests average 16.6 ms, even though accepted requests run the same auth, onboarding and plan plugs plus the controller. Plug order therefore cannot explain the gap. Not yet explained; candidates are larger or slower request bodies from old plugins, the clients themselves, or retry behaviour. Not verified.

Do **not** move `RequirePluginVersion` earlier. `router.ex` places it after `BumpActivity` on purpose (#1588): a request refused before `BumpActivity` never stamps `last_active_at`, and `InactivityCleanup` soft-deletes at 90 days, dropping Qdrant points and S3 attachments for someone who syncs daily on an old plugin.

## Unexplained: dead time before the first DB query

Some slow requests spend seconds in the server span before any child span starts. Verified examples (Tempo, server span):

- `POST /api/auth/token/refresh`: trace `a238dd72c2dab342ca21a8da0d2a7ba7`, 7.83 s total. First DB query starts about 7.8 s in; all DB work is about 11 ms.
- `POST /oauth/token`: trace `1f5ffb0ea8df08c3c261bac34e0f2730`, 10.23 s total. All DB spans fall in the last 25 ms.

Saturation (CPU, DB pool wait) at those times was not checked in this pass.

Candidates, none confirmed:

1. Reading the request body from a slow client.
2. The rate limiter.
3. Auth plugs.
4. Untraced outbound HTTP: Clerk, CIMD document fetch and JWKS fetch have no spans, so any wait on them is invisible.
5. Spans dropped or not propagated. For `/api/mcp`, tool calls that wait on Voyage or Qdrant should show spans (`embedders/voyage.ex`, `vector/qdrant.ex`); a slow MCP trace with only the Bandit span (for example `5b84eda40129f5b0e750deb458fe9d83`, `url.path: unmatched`) shows that nothing was traced, not where the time went.

Next step: add spans around body read, the rate-limit check, each auth plug and the outbound HTTP clients, check MCP span propagation, then re-pull slow traces.

## Code-side findings (not verified against traces)

- **Manifest has no delta**: `manifest/2` (`lib/engram_web/controllers/sync_controller.ex:93-151`) short-circuits only when `since == current`; any other value renders the full vault via `manifest_rows/2` (`:173-206`).
- The **plugin has 5 full-manifest call sites** with no `since_seq` in `src/sync.ts` (1137, 1176, 9494, 11796, 12070); only 7445 passes a seq. One is the delete-guard lookup `manifestOwnerOf` (1127, fetch at 1137), cached for `MANIFEST_OWNERS_TTL_MS = 30_000` (1112).
- `priv/repo/structure.sql` on `origin/main` is **stale** (for example it lacks `cimd_url`). Do not trust it for index checks; read `priv/repo/migrations/` instead.
