# Context Doc: Bulk ingest into a small Qdrant node (mx1) OOMs

_Last verified: 2026-10-25_

## Status
Mitigated by #2229 (`QdrantLayout.@max_segment_size_kb 128_000`, new collections only). Pacing rules below still apply to any bulk copy or re-ingest.

## Environment
Prod Qdrant Cloud mx1 node (0.5 vCPU, 4 GiB), Qdrant 1.19.2. Seen during the v2 to v3 copy of ~302k points (2026-10-25).

## Gotchas (read first)
- **Oversized segments OOM the node.** At `max_segment_size` 1,000,000 KB, segment builds and merges hold the whole sparse index in RAM (~13 KB per point in a build). Anon RSS went 1.45 GB at 143k points, then 2.5, then 3.25 GB, then OOM restarts (RSS cliffs to ~0.3 GB). No data was lost: `points_count` stayed monotonic through every restart.
- **The cap is create-time only.** `create_params/3` sets 128,000 KB; the boot reconcile no longer PATCHes it, so existing clusters (v2) are untouched. A PATCH does not split existing segments, so an existing collection needs drop, recreate and re-copy to get the cap.
- **Strict-mode backpressure does not protect the optimizer.** "Resident memory usage is at N%" refuses writes BEFORE they allocate; `Qdrant.write_error` maps it to `{:error, :qdrant_backpressure}`. A refused write is safe. It does NOT cap the optimizer's own working memory, so a merge can still OOM.
- **GREY status can sit forever.** GREY = optimizations queued, waiting for a write to trigger them. A collection can hold everything unindexed in RAM and never drain. A PATCH with an empty `optimizers_config: {}` triggers them, but with an oversized cap that just starts an OOM-ing merge.
- **Half the metrics vanish after the #1590 wiring change.** Alloy scrapes only the "old" slot's cluster, so the other cluster has no Grafana metrics. Keep the in-app pressure checks running during a copy.
- **Killing the copy task leaves no cursor, but a restart is cheap.** The cursor (`last_chunk_id`) exists only in the report `ClusterDiff.run/3` returns, so a killed run (the v3 move runbook's R3.5a kills with `:kill`) cannot resume from where it stopped. Rerun with `repair: true` from zero: it probes every id but copies only the ones still missing. Prefer letting `run/3` return so the cursor is kept.
- Steady state is small: 185k points with the optimizer idle is ~0.3 GB anon. The danger is only the build/merge window.

## Copy pacing (ClusterDiff)
`Engram.Vector.ClusterDiff` and the second cluster slot were removed after the v3 move (engram-app/Engram#2253); a future copy needs a new tool. The pacing numbers below still hold.
- `Engram.Vector.ClusterDiff.run(source, target, opts)` (removed) walks PG chunk ids and copies only ids missing on the target, so a rerun skips what is already there. `pause_ms` also slows the skip phase.
- Full speed (2,375 pts/s) tripped backpressure within a minute; ~300 pts/s was fine.
- Pace by heap in a loop: resume when heap is 35% or below, stop at 65%, then rerun from the cursor in `{:error, _, %{last_chunk_id: id}}` via `after: id` (that cursor lives only in the returned partial report; after a kill, rerun from zero, see above).

## Failed Approaches / Dead Ends
- PATCH `max_segment_size` on the live collection: existing segments stay oversized.
- `hnsw_config.on_disk` to cut RAM: changing it live rebuilds every segment, which is the same OOM.
- Kicking the optimizer with `optimizers_config: {}` before the cap is in place: starts the OOM merge.

## References
- `lib/engram/vector/qdrant_layout.ex` (`@max_segment_size_kb`, `create_params/3`)
- `lib/engram/vector/qdrant.ex` (backpressure regex, `write_error/2`)
- `lib/engram/vector/cluster_diff.ex`
- `docs/context/qdrant-strict-mode-unindexed-filter.md`
