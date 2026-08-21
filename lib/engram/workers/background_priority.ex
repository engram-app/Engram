defmodule Engram.Workers.BackgroundPriority do
  @moduledoc """
  Demotes the calling job process to BEAM `:low` scheduler priority.

  Indexing is already asynchronous (Oban), but async is not isolated: the
  `embed` and `indexing` queues run on the same schedulers as the Phoenix
  channel processes serving a live sync, and the interactive path gets starved.

  The prod task is **0.5 vCPU** (`cpu = "512"`, engram-infra
  `main/envs/prod/ecs.tf`), so seven concurrent workers (`embed: 5`,
  `indexing: 2`) are heavily oversubscribed. Those limits were sized against
  MEMORY — see the `config/config.exs` comment deriving them from the 1024 MB
  task ceiling — not against CPU.

  Measured on the 2026-08-20 1.7k-note upload, from ECS Container Insights
  (`ECS/ContainerInsights` `CpuUtilized`/`CpuReserved`, CPU units where
  1024 = 1 vCPU) — the only trustworthy per-task CPU source:

      idle baseline   ~22 / 512   (4%)
      during upload   388-454 avg / 512, peak 510.27 / 512  (99.7%)

  So the task was pegged. `beam_stats_run_queue_count` reached 7 and 10 over the
  same window, which is the same fact from the BEAM's side. And at ~100% of a
  CFS quota you are BY DEFINITION throttled: the kernel freezes the cgroup for
  the remainder of each period once the quota is spent.

  Two caveats worth keeping:

  `CpuUtilized` cannot exceed `CpuReserved`, so 510/512 means "consumed
  everything available", NOT "needed exactly 510". True demand is >= that, by an
  unknown margin — the cap hides it.

  Do NOT substitute Oban's `job_processing_duration` for this. It is job WALL
  time and includes waiting on the Voyage HTTP call. An earlier draft of this
  moduledoc derived "1.54 cores of demand" from it; that conflated wall time
  with CPU and is retracted rather than quietly deleted. The same mistake made
  the two tasks look 89/11 imbalanced when their actual CPU was ~390 vs ~510.

  Demoting does not create capacity — the arithmetic above is unchanged by it.
  It decides who gets the contended core first, which is the part the user
  feels.

  A `:low` process is only scheduled when no `:normal` process on that
  scheduler is runnable, which is exactly the ordering we want: the user's
  sync always wins, indexing consumes what is left.

  ## The tradeoff, stated plainly

  `:low` degrades off a cliff, not gracefully. Under *sustained* `:normal`
  load — which a long bulk upload is — these jobs can be starved for a long
  time. That is acceptable here only because indexing is already
  eventually-consistent: search results lag, nothing is lost, and Oban retries
  what times out. It is NOT acceptable for any job on a user-visible deadline,
  so this is opt-in per worker rather than a queue-wide setting.

  If starvation ever shows up as jobs aging out, the better lever is lowering
  queue concurrency (predictable) rather than reaching for something between
  `:low` and `:normal` — BEAM does not offer one.

  In prod the flag is set on the job's own process, which Oban spawns per job,
  so it dies with the job and cannot leak into a pooled or shared process.

  ## Why it is configurable

  Two reasons, and the first is not hypothetical:

  1. `Oban.Testing.perform_job/2` invokes `perform/1` **in the calling test
     process**. Demoting there would strand the test process at `:low` for the
     remainder of the test — a latent flake source on a loaded runner, not a
     job-scoped flag at all. `config/test.exs` sets `:normal`.
  2. `:low` is the one change here that can starve rather than slow. An ops
     kill-switch (`BACKGROUND_JOB_PRIORITY=normal`) reverts it without a
     deploy, which a scheduler change deserves.
  """

  @doc """
  Demote the current process to the configured background priority.

  No-ops when the configured priority is `:normal`. Returns `:ok`.
  """
  @spec demote() :: :ok
  def demote do
    case Application.get_env(:engram, :background_job_priority, :low) do
      :normal -> :ok
      priority -> _ = :erlang.process_flag(:priority, priority)
    end

    :ok
  end
end
