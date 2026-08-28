defmodule Engram.ObanWorkerTimeoutTest do
  # Guard: every Oban worker must define a FINITE `timeout/1`.
  #
  # Oban's default is `:infinity`. A job that blocks — a socket that never
  # returns, a `GenServer.call` with no deadline, a NIF that does not come
  # back — then holds its concurrency slot forever. The queue loses one slot
  # per hung job until it reaches zero, at which point it is stopped and looks
  # *maximally healthy* on every occupancy metric: `executing` sits pinned at
  # the limit while throughput is zero.
  #
  # That is exactly what happened in prod on 2026-08-28 ~07:46 UTC. Both
  # `embed` (5/5 executing) and `indexing` (2/2) were fully occupied by jobs
  # that would never finish. Zero completions, zero exceptions, zero log
  # lines. `Oban.Plugins.Lifeline` did not help: it only rescues jobs whose
  # owning NODE is gone, and the node was alive the whole time. Meanwhile
  # `ReconcileEmbeddings` kept re-enqueueing, so the backlog went 8 → 358
  # scheduled in one cron interval against zero throughput. See #1496.
  #
  # A finite timeout turns "wedged forever, silently" into "fails, retries,
  # frees the slot, and shows up in the error metrics". That is the whole fix.
  #
  # This test enumerates workers from the compiled beam files rather than a
  # hand-kept list, because the failure mode is a NEW worker silently
  # inheriting `:infinity` — a list someone must remember to update cannot
  # catch that.
  use ExUnit.Case, async: true

  # The longest any single job may run. Above this a job is not slow, it is
  # stuck: `Lifeline`'s own `rescue_after` default is 60 minutes, so a timeout
  # beyond it would be dead code.
  @ceiling :timer.minutes(60)

  defp oban_workers, do: Engram.Test.ObanWorkers.all()

  test "there are workers to check at all" do
    # Without this, a broken `oban_workers/0` would make every assertion below
    # vacuously pass over an empty list — the worst outcome for a guard test.
    assert length(oban_workers()) >= 25,
           "found only #{length(oban_workers())} Oban workers; the detection above is\n" <>
             "probably broken, which would make the timeout assertions vacuous."
  end

  test "every worker defines a finite timeout" do
    job = %Oban.Job{args: %{}}

    offenders =
      for mod <- oban_workers(),
          timeout = mod.timeout(job),
          not (is_integer(timeout) and timeout > 0 and timeout <= @ceiling),
          do: {mod, timeout}

    assert offenders == [],
           "these workers do not return a finite timeout in 1..#{@ceiling} ms:\n\n" <>
             Enum.map_join(offenders, "\n", fn {mod, t} ->
               "  #{inspect(mod)} → #{inspect(t)}"
             end) <>
             "\n\n`:infinity` means a hung job holds its concurrency slot forever and the\n" <>
             "queue stops with `executing` pinned at the limit — invisible to every\n" <>
             "occupancy alert. Add `@impl Oban.Worker def timeout(_job), do: :timer.minutes(n)`.\n" <>
             "See #1496."
  end
end
