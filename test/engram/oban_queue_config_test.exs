defmodule Engram.ObanQueueConfigTest do
  # Guard: every Oban worker must enqueue to a queue that is actually
  # registered in `config :engram, Oban, queues: [...]`. A worker pointed
  # at an unregistered queue has no producer on any node, so its jobs sit
  # `available` forever and never execute (the orphaned-queue failure mode
  # that stranded :cleanup + :indexing + :default in prod). Catches it at
  # compile/CI time instead of via a Grafana backlog days later.
  use ExUnit.Case, async: true

  test "every Oban worker's queue is registered in the Oban queues config" do
    configured = MapSet.new(configured_queues())

    {:ok, modules} = :application.get_key(:engram, :modules)

    offenders =
      for mod <- modules,
          Code.ensure_loaded?(mod),
          oban_worker?(mod),
          queue = worker_queue(mod),
          queue not in configured,
          do: {mod, queue}

    assert offenders == [],
           "Oban workers target queues missing from `config :engram, Oban, queues:`.\n" <>
             "Jobs in an unregistered queue have no producer and never execute.\n" <>
             "Add the queue to config/config.exs (or fix the worker's queue:).\n\n" <>
             Enum.map_join(offenders, "\n", fn {mod, q} ->
               "  #{inspect(mod)} -> #{inspect(q)}"
             end)
  end

  # Tripwire against unbounded embed concurrency. The 2026-07-03 OOM crash-loop
  # was NOT caused by embed concurrency itself — it was the Lingua language
  # detector loading ~945 MB of full-accuracy models off-heap during indexing
  # (fixed via `low_accuracy_mode: true`, re-measured at ~55 MB; see LangDetect +
  # docs/context/lingua-language-detection-memory.md). With that bounded, embed: 5
  # is safe (peak ≈ 560 MB under the 1024 MB task). This ceiling just stops the
  # value being cranked into a new memory problem without a fresh measurement.
  test "embed queue concurrency stays within a memory-safe ceiling" do
    embed_limit = configured_queue_limit(:embed)

    assert is_integer(embed_limit) and embed_limit >= 1 and embed_limit <= 8,
           "embed queue concurrency should be 1..8 (got #{inspect(embed_limit)}).\n" <>
             "Above ~8, re-measure the per-node indexing footprint (Lingua models +\n" <>
             "embed working set) against the ECS task memory before raising further —\n" <>
             "see docs/context/lingua-language-detection-memory.md."
  end

  # Tripwire against sizing crdt_checkpoint for the WRONG node.
  #
  # This lane is the overflow for CRDT unbind checkpoints; the inline half is
  # Engram.Notes.CheckpointGate. On a split fleet they live on different nodes,
  # so the worker can afford a big lane (it never runs the gate, and its pool is
  # larger). But config/config.exs is the DEFAULT — it is what an unsplit node
  # runs, and an unsplit node runs BOTH. There the two stack on one pool:
  #
  #     sum(queues) + CheckpointGate.limit()  must fit POOL_SIZE
  #
  # A value tuned for the worker landing here is exactly how you rebuild the
  # 2026-07-09 pool-exhaustion loop on every node that has no role set. Raise
  # the lane for the worker in config/runtime.exs (the ENGRAM_NODE_ROLE=worker
  # arm), never here.
  test "crdt_checkpoint default is sized for a node that ALSO runs the inline gate" do
    lane = configured_queue_limit(:crdt_checkpoint)

    assert is_integer(lane) and lane >= 1 and lane <= 3,
           "crdt_checkpoint default should be 1..3 (got #{inspect(lane)}).\n" <>
             "This is the default every UNSPLIT node runs, and an unsplit node also\n" <>
             "runs the inline CheckpointGate — the two stack on one pool. If you are\n" <>
             "raising this for the dedicated worker, do it in config/runtime.exs\n" <>
             "under the ENGRAM_NODE_ROLE=worker arm instead."
  end

  # The whole point of the runtime override is that it raises ONE queue without
  # dropping the other eight. Config deep-merges nested keyword lists, but that
  # is a language guarantee this config leans on hard enough to pin down: get it
  # wrong and the worker silently boots with crdt_checkpoint as its ONLY queue,
  # and embeds stop for everyone.
  test "a partial queues override merges into the base list rather than replacing it" do
    base = Application.fetch_env!(:engram, Oban)

    merged =
      Config.__merge__(
        [engram: [{Oban, base}]],
        engram: [{Oban, [queues: [crdt_checkpoint: 6]]}]
      )

    queues = merged[:engram][Oban][:queues]

    assert Keyword.get(queues, :crdt_checkpoint) == 6
    assert Keyword.get(queues, :embed) == configured_queue_limit(:embed)

    assert Enum.sort(Keyword.keys(queues)) ==
             Enum.sort(Keyword.keys(Application.fetch_env!(:engram, Oban)[:queues])),
           "the override dropped or added a queue — the worker would boot with the wrong set"
  end

  defp configured_queue_limit(queue) do
    Application.fetch_env!(:engram, Oban)[:queues] |> Keyword.get(queue)
  end

  # The configured queue list. `testing: :manual` (config/test.exs) deep-merges
  # into the base `config/config.exs` Oban config, so `:queues` is the real
  # base list here. Guard against an env that stubs it to `false`/`nil` — that
  # would mean NO worker can run, which is itself a misconfiguration, not a
  # silently-empty allowlist that passes the test vacuously.
  defp configured_queues do
    case Application.fetch_env!(:engram, Oban)[:queues] do
      queues when is_list(queues) and queues != [] ->
        Keyword.keys(queues)

      other ->
        flunk(
          "config :engram, Oban, queues: must be a non-empty keyword list, got: " <>
            inspect(other)
        )
    end
  end

  defp oban_worker?(mod) do
    Oban.Worker in (mod.module_info(:attributes)[:behaviour] || [])
  end

  # Pull the worker's actual queue from a built changeset so it reflects the
  # real `use Oban.Worker, queue:` value (no reliance on private internals).
  # If a worker overrides `new/1` to require args and raises on `%{}`, surface
  # that as its own offender instead of crashing the whole guard.
  defp worker_queue(mod) do
    mod.new(%{})
    |> Ecto.Changeset.get_field(:queue)
    |> String.to_existing_atom()
  rescue
    error -> {:could_not_build, Exception.message(error)}
  end
end
