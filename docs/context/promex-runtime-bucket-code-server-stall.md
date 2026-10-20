# Context Doc: PromEx runtime bucket modules stall the code server

_Last verified: 2026-10-20_

## Status
Fixed by PR engram-app/Engram#2090 (`fix/ci-unit-test-60s-timeouts`). The runner-load part (bottom of this doc) is waiting on a decision from the user.

## Symptom
- Intermittent 60 s `ExUnit.TimeoutError` in unit-tests, with the stack inside `code_server.erl:159 :code_server.call/1`.
  - `PreflightTest` "resolves the real migrations dir": the stack goes through `Application.app_dir/1`. This happened 6 times on 10-19 and 10-20.
  - `FrontmatterParseTest`: the stack goes through `:application_controller.call` from `YamlElixir`'s `Application.start`. application_controller resolves the `.app` file through the code server.
- The same partition log shows `warning: redefining module :"Elixir.engram_qdrant_event_metrics.Bucket_0" (current version defined in memory)`. There were 26-29 of these per CI run across `engram_{crdt,mcp,qdrant,voyage,profiling}_event_metrics.Bucket_N`.
- A rerun usually passes. Do not treat that as a fix.

## Root cause
1. `PromEx.MetricTypes.Event.build/2` (deps/prom_ex/lib/prom_ex/metric_types/event.ex) calls `Module.create(<group>.Bucket_N, use Peep.Buckets.Custom ...)` for every `distribution` without `:peep_bucket_calculator`. It does this **on every `event_metrics/1` call**, not once.
2. The app defines these modules at boot, so every later call (the `test/engram/prom_ex/*` tests call `event_metrics/1` dozens of times) is a redefinition.
3. The code server loads a redefinition with a purge. `code_server.erl` `load_module` calls `do_purge/1`, which calls `erts_code_purger:purge/1`, and that runs `check_process_code` against **every process in the VM**. The code server answers nothing else until the sweep finishes. The sweep's cost grows with process count times CPU contention.
4. `PreflightTest` calls `Application.app_dir` about 105 times (once per migration). It always lands in the same `--partitions` partition as the async `Engram.PromEx.QdrantTest`, which does 3 redefinitions. When those overlap, the loop queues behind every sweep.

This is the same singleton bottleneck as #1210 and #2021. #2021 removed the lazy-loading source by preloading every module in `test_helper.exs`. It did not remove the purge source.

## Repro numbers
Standalone BEAM, OTP 27.3.4.14 / Elixir 1.17.3, `+S 4`. It measures the worst 105x `Application.app_dir` loop while one module is redefined 3 times:

| Processes | CPU hogs | 3 redefinitions | Worst 105x app_dir loop |
|---|---|---|---|
| 20k | 0 | 0.49 s | 0.19 s |
| 20k | 16 | 8.7 s | 8.9 s |
| 100k | 16 | 29.2 s | 29.2 s |

The loop is blocked for the whole sweep. A loaded CI VM running 3 partition BEAMs can reach 60 s.

## The rule
Every histogram in our PromEx plugins passes a **compiled** bucket module:

```elixir
reporter_options: Buckets.opts(Engram.PromEx.Qdrant.RequestDurationBuckets)

defmodule Engram.PromEx.Qdrant.RequestDurationBuckets do
  @moduledoc false
  use Engram.PromEx.Buckets, [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
end
```

- `Engram.PromEx.Buckets` (lib/engram/prom_ex/buckets.ex) is `use Peep.Buckets.Custom` plus `buckets/0`. `opts/1` returns `[buckets:, peep_bucket_calculator:]`.
- `Engram.PromEx.FixedBucketsTest` guards the rule:
  - two `event_metrics/1` calls per plugin print no `redefining module`;
  - every distribution names a compiled module that is not a generated `Bucket_N`;
  - metric names and `le` boundaries are pinned to their values from before the fix. That third test passes against both the old and new code, so dashboards and alerts saw no change.
- Adding a histogram with bare `buckets:` fails `FixedBucketsTest`. Add the new name and boundaries to its `@scraped` map.
- Known gap: `Engram.PromEx.Ecto` calls `PromEx.Plugins.Ecto.event_metrics/1`, which builds the upstream query group's bucket modules before we drop that group. That happens once at boot, and no test calls it, so `FixedBucketsTest` leaves Ecto out.

## Related, open: ResolveOnReadPropertyTest is runner-load bound (WAITING ON THE USER)
- `ResolveOnReadPropertyTest` makes about 4,557 sequential DB round trips. It takes 12 s locally and hit 60 s in runs 39242306840 and 39419192437 (attempt 1, PR #2084). Its stack is wherever it happened to be at 60 s; there is no lock or code server wait.
- Both failures were on SlowRaid `runner-1`/`runner-5`. The PR #2084 job took 10.5 min against a SlowRaid median of 6.1 min, with 12 other jobs on the same VM. The gamingpc median is 3.05 min.
- Capacity mismatch: verify.yml's unit-tests comment assumes "`heavy` (2 runners per VM)". homelab `ansible/inventory.yml` sets SlowRaid `runner_heavy_count: 5`. Each unit-tests job starts 3 BEAMs with 14 schedulers each (`max_cases: 28`) on a 14-vCPU VM, before counting co-tenant jobs.
- Proposed: one unit-tests slot per VM, or `runner_heavy_count: 2`. Then, if needed, size each partition BEAM with `+S nproc/PARTITIONS` and `+sbwt none`. **Not changed. Waiting on the user's decision.**
- How to find these: `gh run list` shows only the LATEST attempt, so a rerun-green run hides its failed attempt 1. Use `gh api repos/engram-app/Engram/actions/runs/<id>/attempts/<n>/jobs`.
