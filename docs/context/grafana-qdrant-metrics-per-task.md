# Qdrant gauges are scraped once per ECS task: never `sum()` them

_Last verified: 2026-11-07 (Grafana Cloud prom, prod)_

The collection-level Qdrant gauges (`engram_prom_ex_qdrant_points`,
`_ram_bytes`, `_disk_bytes`, `_segments`, `_pressure_percent`,
`_collection_green`, `_optimizer_ok`, ...) come from `Engram.PromEx` polling
Qdrant on EVERY app task, web and worker alike. Each task reports the same
collection, labelled by its own `task` (the ECS task IP) and `role`.

Measured 2026-11-07: `engram_prom_ex_qdrant_points` had three series in prod
(tasks `10.30.1.187` web, `10.30.2.80` web, `10.30.2.45` worker), each about
1,005,280 points. `sum(engram_prom_ex_qdrant_points)` reads ~3.0M: the task
count times the real value.

## How to query

- Gauges: `max by (env) (engram_prom_ex_qdrant_points)` (or `max by (...)` on
  whatever grouping you need), or filter to one task: `{role="worker"}`.
- Counters and histograms that count Qdrant-side events seen by every poller:
  `max` of the `rate`, never `sum`.
- Counters of OUR requests (`engram_prom_ex_qdrant_request_total`,
  `_payload_write_*`) are per task by nature: `sum` them.

## Why it bites

A task-count change (a deploy, autoscaling) moves a `sum()` panel with no
change in Qdrant, which reads as growth or loss. Check `count by (task)` first
when a Qdrant number jumps at a deploy.
