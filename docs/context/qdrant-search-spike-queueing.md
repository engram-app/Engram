# Context Doc: Prod Qdrant search latency spikes (search-pool queueing)

_Last verified: 2026-11-17_

## Status
Mechanism proven (queueing, not CPU). Per-search cost driver (page-cache-miss disk IO) likely, NOT proven: there is no disk IO / iowait metric for the Qdrant pod. No fix shipped yet.

## What This Is
Why prod Qdrant search p99 jumps from ~100 ms to ~4-4.7 s in short bursts, and how to measure it. Investigation was read-only (Grafana Prometheus/Tempo/Loki plus one Qdrant `GET /telemetry?details_level=1` via the Grafana Infinity datasource `infinity-qdrant-data`, which holds the key).

## Environment
- Prod Qdrant Cloud, package mx1: 500m CPU / 4 GiB (`engram-infra` `envs/prod/qdrant.tf`, $34.08/mo). Pod CPU limit 0.46 cores, memory limit ~3.8 GB.
- Qdrant 1.19.2, ARM, `system.cores = 1`.
- `search_pool = {mode: high_io, high_io_threads: 4, high_cpu_threads: 1}`: about 4 searches run at once, the rest queue.
- Collection: dense float16 on_disk (3.0 GB, 0.55 GB cached), sparse `keyword` index on_disk (2.43 GB index, 0.75 GB cached; sparse storage 2.5 GB, 0.02 GB cached), on_disk_payload (1.1 GB, 0.55 GB cached), BQ always_ram (0.19 GB). Total 9.7 GB on disk vs 2.0 GB page cache. `hnsw m=0, payload_m=16` (per-tenant graphs). The hot set does not fit in RAM.

## What the spikes are
- **Queueing in the 4-thread search pool.** During a burst every request type slows together: p50 rises 50-200x (3 ms to 200-650 ms) and even by-id retrieve `POST /points` (no search) hit 4.39 s p99. One heavy query would not do that.
- **Source: bursty parallel hybrid searches from ONE MCP client** (~40 `search_notes` per minute, issued in parallel across both web tasks), recurring near :40 each hour (looks scheduled; cadence inferred, not verified). Find the client with the Tempo queries below; do not record user ids in docs.
- **Hybrid bursts hit the timeout; sparse-only bursts do not.** A burst of ~130 light sparse-only queries queued (p50 0.25 s) but p99 stayed under 0.5 s.
- **Not CPU.** Worst spike minute: ~80 searches, CPU 0.013-0.017 cores (~25 ms CPU per search vs seconds of wall time). Night-long 5-min CPU 0.005-0.033 of 0.46 cores. Peak minute (0.073 cores) lined up with an upsert burst, not a search spike.
- **Not the optimizer, set_payload, or update queue** (`collection_running_optimizations` 0-1, update_queue 0, set_payload 0). Upsert bursts of ~400 per 10 min did not spike search on their own.
- Per-search wall time is LIKELY mmap page faults: BQ dense leg with `rescore: true, oversampling: 3.0` reads float16 vectors from disk, the sparse leg reads on-disk posting lists, and payload is on disk.

## Gotchas
- **Qdrant search p99 is CAPPED by the 4 s server timeout.** `server_timeout_s(:search)` = 5000/1000 - 1 = 4 s, client `receive_timeout` 5 s. Values of 4-4.7 s mean "timed out", and the real queue time is longer than the metric shows.
- **Qdrant telemetry shows 500s while the app records 0 errors.** Telemetry had `POST /points/query/batch` 500 x5 at 4.00-4.15 s, but `engram_prom_ex_qdrant_request_total{status="error"}` had no series in 24 h. Why the app did not count them is NOT verified. Read Qdrant's own telemetry, not just the app counter.
- **The CPU metric is real**, not a broken scrape: daily max over two weeks is 0.21-0.43 cores, so it can show near-limit use. Low CPU during spikes is a true reading.
- cadvisor scrapes every 60 s: use `[2m]` rates at minimum for 1-minute views.
- Page cache = `working_set - rss`, flat at 1.61-1.63 GB through the burst.
- Hardware counters (`vector_io_read`, `payload_index_io_read`) are logical bytes, not disk ops; they rose 2.5x in the burst minute but do not prove disk IO.
- Tempo samples: only ~17 of ~200 `qdrant.query` spans kept, so in-flight concurrency is not measurable from traces.
- Operator bastion runs that do bulk `POST /points` retrieves can overlap and add to a spike window.

## Key Commands / Patterns (Grafana, `grafanacloud-prom` unless noted)
```promql
# Qdrant CPU (5m) and throttle ratio
max without (task, role) (rate(container_cpu_usage_seconds_total{job="prometheus.scrape.qdrant_sys",container="qdrant"}[5m]))
rate(container_cpu_cfs_throttled_periods_total{job="prometheus.scrape.qdrant_sys",container="qdrant"}[5m])
  / rate(container_cpu_cfs_periods_total{job="prometheus.scrape.qdrant_sys",container="qdrant"}[5m])

# Validate the CPU metric can show load (daily max, 1m resolution)
max_over_time(max(rate(container_cpu_usage_seconds_total{job="prometheus.scrape.qdrant_sys",container="qdrant"}[2m]))[1d:1m])

# Server-side search latency (remember: capped at ~4 s)
histogram_quantile(0.99, sum by (le) (max without (task) (rate(rest_responses_duration_seconds_bucket{endpoint=~".*points/query.*"}[5m]))))
# Server request counts by endpoint (10m buckets)
max without (task) (increase(rest_responses_duration_seconds_count[10m]))

# App-side search counts and errors
sum by (op) (increase(engram_prom_ex_qdrant_request_total{op=~"hybrid_search|sparse_search|search"}[5m]))
engram_prom_ex_qdrant_request_total{status="error"}
# MCP search rate per minute
sum(increase(engram_prom_ex_mcp_tool_total{tool="search_notes"}[1m]))
```
```traceql
# grafanacloud-traces: which client drives the burst
{ name = "POST /api/mcp" } | count_over_time() by (span.app.user_id, span.gen_ai.tool.name)
{ span.gen_ai.tool.name = "search_notes" } | count_over_time() by (span.app.user_id)
```
Qdrant telemetry: `GET /telemetry?details_level=1` through the Infinity datasource `infinity-qdrant-data` gives the search pool config, per-endpoint lifetime avg/max, and 5xx counts with timestamps. Lifetime (since 10-25): `/points/query/batch` (hybrid) avg 447 ms; `/points/query` avg 4.3 ms; `POST /points` retrieve avg 248 ms.

Query shape lives in `lib/engram/vector/qdrant.ex` `hybrid_search_body/3` (one `/query/batch`, dense BQ+rescore leg and sparse leg with `tenant_idf`, both filtered on `u`) and `Search` (pool = `max(limit*4, 20)` for group/rerank/MMR, `@widen_factor 16` for too-wide filters; MMR does a follow-up by-id retrieve with vectors).

## Options (ranked, query-side first)
1. **App-side search concurrency limit with per-user fairness**: e.g. at most 2 in-flight Qdrant searches per user and a global cap near the pool size (4), short BEAM wait queue, fail fast past the timeout. Stops one MCP loop starving everyone. Dev only, $0.
2. **Trim per-search IO**: BQ oversampling 3.0 to 2.0 (~1/3 fewer rescore reads); cap hybrid prefetch at page size when no rerank/MMR; skip the `with_vector` retrieve for MMR or run MMR on quantized vectors. Needs a staging recall check. $0.
3. **Short-TTL cache of identical (user, query, scope) results.** Repeat rate NOT verified; add a hashed-query counter first. $0.
4. **Rate-limit `search_notes` per MCP client** (existing RateLimiter). Blunt, hurts legit agents.
5. **Resize, last.** gpx2 (1 vCPU, same 4 GiB, +$17.98/mo) is unlikely to help since CPU is not the bottleneck. A package with 8+ GiB RAM would attack the IO cause (price not looked up). Owner's money decision, engram-infra TF only, single node means a restart outage.

To settle the IO hypothesis: (a) disk IOPS/latency for the pod from Qdrant Cloud console/support; (b) staging replay of the same query shape at concurrency 1/4/16 on a cold cache; (c) the burst client's point count (read-only count on `u`).

## Failed Approaches / Dead Ends
- Raising the search timeout: longer queues, same throughput. Not recommended.
- Moving the sparse index to RAM: 2.4 GB does not fit in 3.8 GB alongside the rest.
- Blaming upserts or the optimizer: bursts of each were checked minute by minute and did not line up with spikes.

## References
- `lib/engram/vector/qdrant.ex`, `lib/engram/search.ex`
- `engram-infra` `envs/prod/qdrant.tf` (package, upgrade options)
- `docs/context/qdrant-small-node-ingest-oom.md`, `docs/context/qdrant-payload-put-slowdown-2026-10-26.md`
